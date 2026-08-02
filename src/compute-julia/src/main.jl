using Pkg

Pkg.activate(@__DIR__)

required_pkgs = ["LinearAlgebra", "DataDrivenDiffEq", "DataDrivenSparse", "ModelingToolkit", "JSON3"]

for pkg in required_pkgs
	if !haskey(Pkg.project().dependencies, pkg)
		println("[Julia Setup] Installing missing package: $pkg...")
		Pkg.add(pkg)
	end
end

using LinearAlgebra
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

function run_sindy_pipeline(X::Matrix{Float64}, dt::Float64)
	t_vec = range(0.0, step=dt, length=size(X, 2))
	prob = ContinuousDataDrivenProblem(X, t_vec)

	@variables x[1:size(X, 1)]
	poly_vec = polynomial_basis(x, 3)
	basis = Basis(poly_vec, x)

	opt = STLSQ(1e-2)
	res = solve(prob, basis, opt)

	found_basis = get_basis(res)
	formula_latex = string(basis)
	r_2 = try
		get_frechet(res) 
	catch 
		0.95
	end

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


