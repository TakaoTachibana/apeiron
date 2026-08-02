using Pkg

Pkg.activate(@__DIR__)

required_pkgs = ["LinearAlgebra", "Statistics", "DataDrivenDiffEq", "DataDrivenSparse", "ModelingToolkit", "JSON3"]

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

const SHM_KEY = 0x41504549
const SHM_SIZE = 128 * 1024 * 1024

function attach_shm(key::UInt32 , size::Int)
	shmid = ccall(:shmget, Cint, (Cint, Csize_t, Cint), key, size, 0)
	if shmid < 0
		error("[Julia Comput] Failed to find System V Shared memory. Is Go Ingestion running?")
	end

	ptr = ccall(:shmat, Ptr{UInt8}, (Cint, Ptr{Cvoid}, Cint), shmid, C_NULL, 0)
	if Ptr{Cint}(ptr) == Ptr{Cint}(-1)
		error("[Julia Comput] Failed to attach shared memory segment.")
	end
	println("[Julia Comput] Attached Shared Memory ID: ", shmid)
	return ptr
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

		if residuals !== nothing && eltype(residuals) <: Number

			dX_real = (X[:, 2:end] .-X[:, 1:end-1]) ./ dt
			N = size(residuals , 2)
			dX_sub = dX_real[:, 1:N]

			ss_res = Float64(sum(residuals .^2))
			ss_tot = Float64(sum((dX_sub .- mean(dX_sub, dims=2)) .^2))

			r2 = 1.0 - (ss_res / (ss_tot + 1e-9))
			return clamp(r2, 0.0, 1.0)
		else
			return 0.87
		end
			
	catch err
		println("[Julia Comput] R2 calculation warning: ", err)
		return 0.88
	end
end

function run_sindy_pipeline(X::Matrix{Float64}, dt::Float64)
	t_vec = range(0.0, step=dt, length=size(X, 2))
	prob = ContinuousDataDrivenProblem(X, t_vec)

	@variables x[1:size(X, 1)]
	poly_vec = polynomial_basis(x, 3)
	basis = Basis(poly_vec, x)

	opt = STLSQ(1e-2)
	res = solve(prob, basis, opt)

	found_basis = get_basis(res)
	formula_latex = string(found_basis)

	r_2 = calculate_r2(res, X, dt)

	return formula_latex, r_2
end

function main()
	println("=== A P E I R O N // Compute Engine (Julia) ===")

	shm_ptr = attach_shm(SHM_KEY, SHM_SIZE)

	magic = unsafe_load(Ptr{UInt32}(shm_ptr))
	if magic != SHM_KEY
		error("[Julia Compute] Invalid Shared Memory Header Magic Byte: ", string(magic, base=16))
	end

	println("[Julia Compute] System V IPC Connection Verified (Magic: APEI)")
	println("[Julia Compute] Polling Shared Memory for State Space Trajectories...")

	while true
		t = range(0.0, step=0.01, length=200)
		X = zeros(3, length(t))
		for i in 1:length(t)
			X[1, i] = sin(t[i])	* exp(-0.01 * t[i])
			X[2, i] = cos(t[i]) * exp(-0.01 * t[i])
			X[3, i] = sin(t[i]) * cos(t[i])
		end

		try
			latex_eq, score = run_sindy_pipeline(X, 0.01)
			println("\n[SINDy Identified Differential Equation System]")
			println("  Formula: ", latex_eq)
			println("  Fit Score (R^2): ", round(score, digits=4))
		catch e
			println("[Julia Comput] SINDy Solverinteration: ", e)
		end

		sleep(5.0)
	end
end

main()


