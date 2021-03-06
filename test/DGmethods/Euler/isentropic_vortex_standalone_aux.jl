# Standard isentropic vortex test case.  For a more complete description of
# the setup see for Example 3 of:
#
# @article{ZHOU2003159,
#   author = {Y.C. Zhou and G.W. Wei},
#   title = {High resolution conjugate filters for the simulation of flows},
#   journal = {Journal of Computational Physics},
#   volume = {189},
#   number = {1},
#   pages = {159--179},
#   year = {2003},
#   doi = {10.1016/S0021-9991(03)00206-7},
#   url = {https://doi.org/10.1016/S0021-9991(03)00206-7},
# }
#
# This version runs the isentropic vortex as a stand alone test (no dependence
# on CLIMA moist thermodynamics)

using MPI
using CLIMA
using CLIMA.Topologies
using CLIMA.Grids
using CLIMA.DGBalanceLawDiscretizations
using CLIMA.DGBalanceLawDiscretizations.NumericalFluxes
using CLIMA.MPIStateArrays
using CLIMA.LowStorageRungeKuttaMethod
using CLIMA.ODESolvers
using CLIMA.GenericCallbacks
using LinearAlgebra
using StaticArrays
using Logging, Printf, Dates
using CLIMA.Vtk

@static if haspkg("CuArrays")
  using CUDAdrv
  using CUDAnative
  using CuArrays
  CuArrays.allowscalar(false)
  const ArrayTypes = (CuArray,)
else
  const ArrayTypes = (Array,)
end

const _nstate = 5
const _ρ, _U, _V, _W, _E = 1:_nstate
const stateid = (ρid = _ρ, Uid = _U, Vid = _V, Wid = _W, Eid = _E)
const statenames = ("ρ", "U", "V", "W", "E")
const γ_exact = 7 // 5
if !@isdefined integration_testing
  const integration_testing =
    parse(Bool, lowercase(get(ENV,"JULIA_CLIMA_INTEGRATION_TESTING","false")))
  using Random
end

# preflux computation
@inline function preflux(Q, QV, aux, t)
  γ::eltype(Q) = γ_exact
  @inbounds ρ, Uδ, Vδ, Wδ, E= Q[_ρ], Q[_U], Q[_V], Q[_W], Q[_E]
  @inbounds U, V, W = Uδ-aux[1], Vδ-aux[2], Wδ-aux[3]
  ρinv = 1 / ρ
  u, v, w = ρinv * U, ρinv * V, ρinv * W
  ((γ-1)*(E - ρinv * (U^2 + V^2 + W^2) / 2), u, v, w, ρinv)
end

@inline function computeQjump!(ΔQ, QM, auxM, QP, auxP)
  @inbounds begin
    ΔQ[_ρ] = QM[_ρ] - QP[_ρ]
    ΔQ[_U] = (QM[_U] - auxM[1]) - (QP[_U] - auxP[1])
    ΔQ[_V] = (QM[_V] - auxM[2]) - (QP[_V] - auxP[2])
    ΔQ[_W] = (QM[_W] - auxM[3]) - (QP[_W] - auxP[3])
    ΔQ[_E] = QM[_E] - QP[_E]
  end
end

@inline function auxiliary_state_initialization!(aux, x, y, z)
  r2 = x^2 + y^2 + z^2
  @inbounds aux[1], aux[2], aux[3] = cos(π * x), sin(π * y), cos(π * r2)
end

# max eigenvalue
@inline function wavespeed(n, Q, aux, t, P, u, v, w, ρinv)
  γ::eltype(Q) = γ_exact
  @inbounds abs(n[1] * u + n[2] * v + n[3] * w) + sqrt(ρinv * γ * P)
end

# physical flux function
eulerflux!(F, Q, QV, aux, t) =
eulerflux!(F, Q, QV, aux, t, preflux(Q, QV, aux, t)...)

@inline function eulerflux!(F, Q, QV, aux, t, P, u, v, w, ρinv)
  @inbounds begin
    ρ, Uδ, Vδ, Wδ, E = Q[_ρ], Q[_U], Q[_V], Q[_W], Q[_E]
    U, V, W = Uδ-aux[1], Vδ-aux[2], Wδ-aux[3]

    F[1, _ρ], F[2, _ρ], F[3, _ρ] = U          , V          , W
    F[1, _U], F[2, _U], F[3, _U] = u * U  + P , v * U      , w * U
    F[1, _V], F[2, _V], F[3, _V] = u * V      , v * V + P  , w * V
    F[1, _W], F[2, _W], F[3, _W] = u * W      , v * W      , w * W + P
    F[1, _E], F[2, _E], F[3, _E] = u * (E + P), v * (E + P), w * (E + P)
  end
end

# initial condition
const halfperiod = 5
function isentropicvortex!(Q, t, x, y, z, aux)
  DFloat = eltype(Q)

  γ::DFloat    = γ_exact
  uinf::DFloat = 2
  vinf::DFloat = 1
  Tinf::DFloat = 1
  λ::DFloat    = 5

  xs = x - uinf*t
  ys = y - vinf*t

  # make the function periodic
  xtn = floor((xs+halfperiod)/(2halfperiod))
  ytn = floor((ys+halfperiod)/(2halfperiod))
  xp = xs - xtn*2*halfperiod
  yp = ys - ytn*2*halfperiod

  rsq = xp^2 + yp^2

  u = uinf - λ*(1//2)*exp(1-rsq)*yp/π
  v = vinf + λ*(1//2)*exp(1-rsq)*xp/π
  w = zero(DFloat)

  ρ = (Tinf - ((γ-1)*λ^2*exp(2*(1-rsq))/(γ*16*π*π)))^(1/(γ-1))
  p = ρ^γ
  U = ρ*u + aux[1]
  V = ρ*v + aux[2]
  W = ρ*w + aux[3]
  E = p/(γ-1) + (1//2)*ρ*(u^2 + v^2 + w^2)

  if integration_testing
    @inbounds Q[_ρ], Q[_U], Q[_V], Q[_W], Q[_E] = ρ, U, V, W, E
  else
    @inbounds Q[_ρ], Q[_U], Q[_V], Q[_W], Q[_E] =
    10+rand(), rand(), rand(), rand(), 10+rand()
  end

end

function main(mpicomm, DFloat, topl::AbstractTopology{dim}, N, timeend,
              ArrayType, dt) where {dim}

  grid = DiscontinuousSpectralElementGrid(topl,
                                          FloatType = DFloat,
                                          DeviceArray = ArrayType,
                                          polynomialorder = N,
                                         )

  # spacedisc = data needed for evaluating the right-hand side function
  spacedisc = DGBalanceLaw(grid = grid,
                           length_state_vector = _nstate,
                           flux! = eulerflux!,
                           numerical_flux! = (x...) ->
                           NumericalFluxes.rusanov!(x..., eulerflux!,
                                                    wavespeed,
                                                    preflux,
                                                    computeQjump!),
                           auxiliary_state_length = 3,
                           auxiliary_state_initialization! =
                           auxiliary_state_initialization!,
                          )

  # This is a actual state/function that lives on the grid
  initialcondition(Q, x...) = isentropicvortex!(Q, DFloat(0), x...)
  Q = MPIStateArray(spacedisc, initialcondition)

  lsrk = LowStorageRungeKutta(spacedisc, Q; dt = dt, t0 = 0)

  eng0 = norm(Q)
  @info @sprintf """Starting
  norm(Q₀) = %.16e""" eng0

  # Set up the information callback
  starttime = Ref(now())
  cbinfo = GenericCallbacks.EveryXWallTimeSeconds(60, mpicomm) do (s=false)
    if s
      starttime[] = now()
    else
      energy = norm(Q)
      @info @sprintf """Update
  simtime = %.16e
  runtime = %s
  norm(Q) = %.16e""" ODESolvers.gettime(lsrk) Dates.format(convert(Dates.DateTime, Dates.now()-starttime[]), Dates.dateformat"HH:MM:SS") energy
    end
  end

  #= Paraview calculators:
  P = (0.4) * (E  - (U^2 + V^2 + W^2) / (2*ρ) - 9.81 * ρ * coordsZ)
  theta = (100000/287.0024093890231) * (P / 100000)^(1/1.4) / ρ
  =#
  step = [0]
  mkpath("vtk")
  cbvtk = GenericCallbacks.EveryXSimulationSteps(100) do (init=false)
    outprefix = @sprintf("vtk/isentropicvortex_aux_%dD_mpirank%04d_step%04d",
                         dim, MPI.Comm_rank(mpicomm), step[1])
    @debug "doing VTK output" outprefix
    writevtk(outprefix, Q, spacedisc, statenames,
             spacedisc.auxstate, ("aU", "aV", "aW"))
    step[1] += 1
    nothing
  end

  # solve!(Q, lsrk; timeend=timeend, callbacks=(cbinfo, ))
  solve!(Q, lsrk; timeend=timeend, callbacks=(cbinfo, cbvtk))

  # Print some end of the simulation information
  engf = norm(Q)
  if integration_testing
    Qe = MPIStateArray(spacedisc,
                       (Q, x...) -> isentropicvortex!(Q, DFloat(timeend), x...))
    engfe = norm(Qe)
    errf = euclidean_distance(Q, Qe)
    @info @sprintf """Finished
    norm(Q)                 = %.16e
    norm(Q) / norm(Q₀)      = %.16e
    norm(Q) - norm(Q₀)      = %.16e
    norm(Q - Qe)            = %.16e
    norm(Q - Qe) / norm(Qe) = %.16e
    """ engf engf/eng0 engf-eng0 errf errf / engfe
  else
    @info @sprintf """Finished
    norm(Q)            = %.16e
    norm(Q) / norm(Q₀) = %.16e
    norm(Q) - norm(Q₀) = %.16e""" engf engf/eng0 engf-eng0
  end
  integration_testing ? errf : (engf / eng0)
end

function run(mpicomm, ArrayType, dim, Ne, N, timeend, DFloat, dt)
  brickrange = ntuple(j->range(DFloat(-halfperiod); length=Ne[j]+1,
                               stop=halfperiod), dim)
  topl = BrickTopology(mpicomm, brickrange, periodicity=ntuple(j->true, dim))
  main(mpicomm, DFloat, topl, N, timeend, ArrayType, dt)
end

using Test
let
  MPI.Initialized() || MPI.Init()
  Sys.iswindows() || (isinteractive() && MPI.finalize_atexit())
  mpicomm = MPI.COMM_WORLD
  ll = uppercase(get(ENV, "JULIA_LOG_LEVEL", "INFO"))
  loglevel = ll == "DEBUG" ? Logging.Debug :
  ll == "WARN"  ? Logging.Warn  :
  ll == "ERROR" ? Logging.Error : Logging.Info
  logger_stream = MPI.Comm_rank(mpicomm) == 0 ? stderr : devnull
  global_logger(ConsoleLogger(logger_stream, loglevel))
  @static if haspkg("CUDAnative")
    device!(MPI.Comm_rank(mpicomm) % length(devices()))
  end

  if integration_testing
    timeend = 1
    numelem = (5, 5, 1)

    polynomialorder = 4

    expected_error = Array{Float64}(undef, 2, 3) # dim-1, lvl
    expected_error[1,1] = 5.7115689019456284e-01
    expected_error[1,2] = 6.9418982796501105e-02
    expected_error[1,3] = 3.2927550219120443e-03
    expected_error[2,1] = 1.8061566743070017e+00
    expected_error[2,2] = 2.1952209848914694e-01
    expected_error[2,3] = 1.0412605646170595e-02
    lvls = size(expected_error, 2)

    for ArrayType in ArrayTypes
      for DFloat in (Float64,) #Float32)
        for dim = 2:3
          err = zeros(DFloat, lvls)
          for l = 1:lvls
            Ne = ntuple(j->2^(l-1) * numelem[j], dim)
            dt = 1e-2 / Ne[1]
            nsteps = ceil(Int64, timeend / dt)
            dt = timeend / nsteps
            @info (ArrayType, DFloat, dim)
            err[l] = run(mpicomm, ArrayType, dim, Ne, polynomialorder, timeend,
                         DFloat, dt)
            @test err[l] ≈ DFloat(expected_error[dim-1, l])
          end
          @info begin
            msg = ""
            for l = 1:lvls-1
              rate = log2(err[l]) - log2(err[l+1])
              msg *= @sprintf("\n  rate for level %d = %e\n", l, rate)
            end
            msg
          end
        end
      end
    end
  else
    numelem = (3, 4, 5)
    dt = 1e-3
    timeend = 2dt

    polynomialorder = 4

    check_engf_eng0 = Dict{Tuple{Int64, Int64, DataType}, AbstractFloat}()
    check_engf_eng0[2, 1, Float64] = 9.9999889893859584e-01
    check_engf_eng0[3, 1, Float64] = 9.9999669139386949e-01
    check_engf_eng0[2, 3, Float64] = 9.9999933683840259e-01
    check_engf_eng0[3, 3, Float64] = 9.9999717798502208e-01

    for ArrayType in ArrayTypes
      for DFloat in (Float64,) #Float32)
        for dim = 2:3
          Random.seed!(0)
          @info (ArrayType, DFloat, dim)
          engf_eng0 = run(mpicomm, ArrayType, dim, numelem[1:dim],
                          polynomialorder, timeend, DFloat, dt)
          @test check_engf_eng0[dim, MPI.Comm_size(mpicomm), DFloat] ≈ engf_eng0
        end
      end
    end
  end
end

isinteractive() || MPI.Finalize()

nothing
