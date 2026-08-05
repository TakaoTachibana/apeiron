using Pkg

Pkg.activate(@__DIR__)

required_pkgs = ["LinearAlgebra", "Statistics", "DataDrivenDiffEq", "DataDrivenSparse", "ModelingToolkit", "JSON3", "HTTP"]

for pkg in required_pkgs
	if !haskey(Pkg.project().dependencies, pkg)
		println("[Julia Setup] Installing missing package: $pkg...")
		Pkg.add(pkg)
	end
end

using LinearAlgebra
using Statistics
using DataDrivenDiffEq
using DataDrivenSparse
using ModelingToolkit
using JSON3
using HTTP

const SHM_KEY = 0x41504549
const SHM_SIZE = 128 * 1024 * 1024
const DATA_OFFSET = 64 
const RING_SIZE = UInt64(SHM_SIZE - DATA_OFFSET)
const GATEWAY_URL = "http://localhost:5236/api/attractors"

const FLAG_TDA_OFFSET = 32
const FLAG_SINDY_OFFSET = 36

function attach_shm(key::UInt32 , size::Int)
	shmid = ccall(:shmget, Cint, (Cint, Csize_t, Cint), key, size, 0)
	if shmid < 0
		error("[Julia Compute] Failed to find System V Shared memory. Is Go Ingestion running?")
	end

	ptr = ccall(:shmat, Ptr{UInt8}, (Cint, Ptr{Cvoid}, Cint), shmid, C_NULL, 0)
	if Ptr{Cint}(ptr) == Ptr{Cint}(-1)
		error("[Julia Compute] Failed to attach shared memory segment.")
	end
	println("[Julia Compute] Attached Shared Memory ID: ", shmid)
	return ptr
end

@inline function safe_read_byte(shm_ptr::Ptr{UInt8}, abs_pos::UInt64)
	rel_pos = abs_pos % RING_SIZE
	return unsafe_load(shm_ptr + DATA_OFFSET + rel_pos)
end

@inline function safe_read_uint32(shm_ptr::Ptr{UInt8}, abs_pos::UInt64)
	b1 = UInt32(safe_read_byte(shm_ptr, abs_pos))
	b2 = UInt32(safe_read_byte(shm_ptr, abs_pos + 1))
	b3 = UInt32(safe_read_byte(shm_ptr, abs_pos + 2))
	b4 = UInt32(safe_read_byte(shm_ptr, abs_pos + 3))
	return b1 | (b2 << 8) | (b3 << 16) | (b4 << 24)
end

function check_and_clear_tda_flag(shm_ptr::Ptr{UInt8})
	flag_ptr = Ptr{UInt32}(shm_ptr + FLAG_TDA_OFFSET)
	flag_val = unsafe_load(flag_ptr)
	if flag_val == 1
		unsafe_store!(flag_ptr, UInt32(0))
		return true
	end
	return false
end
	
function parse_jetstream_features(json_bytes::Vector{UInt8})
	try
		x1 = Float64(length(json_bytes))
		x3 = Float64(sum(Int.(json_bytes[1:min(end, 50)])))

		str = String(json_bytes)
		x2 = Float64(count(c -> c == ':', str)) + 1.0

		return [x1, x2, x3]
	catch
		return [100.0, 10.0, 5.0]
	end
end

function read_trajectory_from_shm(shm_ptr::Ptr{UInt8}, last_read_pos::UInt64, window_size::Int=200)
	write_idx = unsafe_load(Ptr{UInt64}(shm_ptr + 8))

	if write_idx < DATA_OFFSET + 512
		return nothing, write_idx, last_read_pos
	end

	start_pos = last_read_pos
	if write_idx > start_pos + 1024 * 1024
		start_pos = write_idx - 1024 * 1024
	end

	if start_pos < DATA_OFFSET
		start_pos = DATA_OFFSET
	end

	collected_vecs = Vector{Vector{Float64}}()
	curr_pos = start_pos

	while curr_pos + 4 < write_idx
		pkt_len = safe_read_uint32(shm_ptr, curr_pos)

		if pkt_len > 0 && pkt_len < 65536 && (curr_pos + 4 + pkt_len <= write_idx)
			bytes = zeros(UInt8, pkt_len)

			for b in 1:pkt_len
				bytes[b] = safe_read_byte(shm_ptr, curr_pos + 4 + (b - 1))
			end

			push!(collected_vecs, parse_jetstream_features(bytes))
			curr_pos += (4 + pkt_len)
		else
			curr_pos += 1
		end

		if length(collected_vecs) >= 1000
			break
		end
	end

	if length(collected_vecs) < 10
		return nothing, write_idx, curr_pos
	end

	selected = collected_vecs[max(1, end - window_size + 1):end]
	N = length(selected)
	X = zeros(Float64, 3, N)

	for i in 1:N
		X[:, i] = selected[i]
	end

	if var(X) < 1e-6
		return nothing, write_idx, curr_pos
	end

	return X, write_idx, curr_pos
end

function calculate_r2(res, X::Matrix{Float64}, dt::Float64)
	try
		residuals = try
			get_residuals(res)
		catch
			try
				res.residuals
			catch
				nothing
			end
		end

		residuals === nothing && return 0.0

		dX_real = (X[:, 2:end] .-X[:, 1:end-1]) ./ dt
		ss_tot = Float64(sum((dX_real .- mean(dX_real, dims=2)) .^2))

		ss_res = 0.0

		if residuals isa Number
			ss_res = Float64(residuals)
		elseif residuals isa AbstractArray && !isempty(residuals)
			ss_res = Float64(sum(residuals .^ 2))
		else 
			return 0.0
		end
		
		r2 = 1.0 - (ss_res / (ss_tot + 1e-9))
		return clamp(r2, 0.0, 1.0)
		
	catch err
		println("[Julia Comput] R2 calculation warning: ", err)
		return 0.0
	end
end

function smooth_trajectory(X::Matrix{Float64}, window::Int=20)
	X_smooth = zeros(size(X)) 
	N = size(X, 2)
	half_window = div(window, 2)
	for i in 1:size(X, 1)
		for j in 1:N
			s_idx = max(1, j - half_window)
			e_idx = min(N, j + half_window)
			X_smooth[i, j] = mean(X[i, s_idx:e_idx])
		end
	end
	return X_smooth
end

function post_attractor_to_gateway(latex_eq::String, score::Float64)
	try
		payload = JSON3.write(Dict("FormulaLatex" => latex_eq, "RSquared" => Float32(score)))
		resp = HTTP.post(GATEWAY_URL, ["Content-Type" => "application/json"], payload)
		if resp.status == 201 || resp.status == 200
			println("[Julia Compute] Successfully posted attractor formula to Gateway.")
		end
	catch err
		println("[Julia Compute] Gateway post skipped or failed (Gateway running?): ", err)
	end
end

function run_sindy_pipeline(X_raw::Matrix{Float64}, dt::Float64; is_disrupted::Bool=false)
	smooth_win = is_disrupted ? 10 : 20
	X_smoothed = smooth_trajectory(X_raw, smooth_win)

	mu = mean(X_smoothed, dims=2)
	sigma = std(X_smoothed, dims=2) .+ 1e-9
	sigma_safe = [s < 1e-6 ? 1.0 : s for s in vec(sigma)]
	X = (X_smoothed .- mu) ./ sigma_safe

	dX = (X[:, 2:end] .- X[:, 1:end-1]) ./ dt
	X_prob = X[:, 1:end-1]
	t_prob = range(0.0, step=dt, length=size(X_prob, 2))

	try
		prob = ContinuousDataDrivenProblem(X_prob, t_prob, DX = dX)

		@variables x[1:size(X, 1)]
		poly_vec = polynomial_basis(x, 1)
		basis = Basis(poly_vec, x)

		threshold = is_disrupted ? 0.02 : 0.05
		opt = STLSQ(threshold)
		res = solve(prob, basis, opt)

		found_basis = get_basis(res)
		formula_latex = string(found_basis)

		r_2 = calculate_r2(res, X, dt)

		return formula_latex, r_2, mu, sigma
	catch err
		return "dx/dt = 0 (Error: $(err))", 0.0, mu, sigma
	end
end

function main()
	println("=== A P E I R O N // Compute Engine (Julia) ===")

	shm_ptr = attach_shm(SHM_KEY, SHM_SIZE)

	magic = unsafe_load(Ptr{UInt32}(shm_ptr))
	if magic != SHM_KEY
		error("[Julia Compute] Invalid Shared Memory Header Magic Byte: ", string(magic, base=16))
	end

	println("[Julia Compute] System V IPC Direct Ring-Buffer Access Verified (Magic: APEI)")

	last_processed_idx = UInt64(0)
	read_pos = UInt64(DATA_OFFSET)

	while true
		tda_disrupted = check_and_clear_tda_flag(shm_ptr)
		X, current_write_idx, next_read_pos = read_trajectory_from_shm(shm_ptr, read_pos, 200)
		read_pos = next_read_pos

		if X !== nothing && current_write_idx > last_processed_idx
			last_processed_idx = current_write_idx

			if tda_disrupted
				println("\n[Julia Compute] META-REWRITE TRIGGERED BY R (TDA DISRUPTION DETECTED!)")
			end

			latex_eq, score, mu, sigma = run_sindy_pipeline(X, 0.01, is_disrupted=tda_disrupted)
			println("\n[SINDy Identified Differential Equation System]")
			println("  Write Index: ", current_write_idx)
			println("  Mode: ",tda_disrupted ? "RE-SINDY (META-REWRITE)" : "STANDARD")
			println("  Data Mean mu: ", round.(vec(mu), digits=4))
			println("  Data Std sigma: ", round.(vec(sigma), digits=4))
			println("  Formula: ", latex_eq)
			println("  Fit Score (R^2): ", round(score, digits=4))

			post_attractor_to_gateway(latex_eq, score)
		else 
			if X === nothing
				println("[Julia Compute] Parsing Bluesky Jetstream JSON from SHM (Write Index: ", current_write_idx, ")...")
			end
		end

		sleep(2.0)
	end
end

main()


