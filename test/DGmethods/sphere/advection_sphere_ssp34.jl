# Advection on the Sphere test case.
#
# This is a case similar to the one presented in:
# @article{WILLIAMSON1992211,
#   title = {A standard test set for numerical approximations to the
#            shallow water equations in spherical geometry},
#   journal = {Journal of Computational Physics},
#   volume = {102},
#   number = {1},
#   pages = {211 - 224},
#   year = {1992},
#   doi = {10.1016/S0021-9991(05)80016-6},
#   url = {https://doi.org/10.1016/S0021-9991(05)80016-6},
# }
#
# This version runs the advection on the sphere as a stand alone test (no
# dependence on CLIMA moist thermodynamics)
#--------------------------------#
#--------------------------------#
# Can be run with:
# Integration Testing: JULIA_CLIMA_INTEGRATION_TESTING=true mpirun -n 1 julia --project=@. advection_sphere_ssp34.jl
# No Integration Testing: JULIA_CLIMA_INTEGRATION_TESTING=false mpirun -n 2 julia --project=@. advection_sphere_ssp34.jl
#--------------------------------#
#--------------------------------#
# Can be run on the GPU with:
# Integration Testing: JULIA_CLIMA_INTEGRATION_TESTING=true mpirun -n 1 julia --project=/home/fxgiraldo/CLIMA/env/gpu advection_sphere_ssp34.jl
# No Integration Testing: JULIA_CLIMA_INTEGRATION_TESTING=false mpirun -n 1 julia --project=/home/fxgiraldo/CLIMA/env/gpu advection_sphere_ssp34.jl
#--------------------------------#
#--------------------------------#

using MPI
using CLIMA
using CLIMA.Topologies
using CLIMA.Grids
using CLIMA.DGBalanceLawDiscretizations
using CLIMA.DGBalanceLawDiscretizations.NumericalFluxes
using CLIMA.MPIStateArrays
using CLIMA.LowStorageRungeKuttaMethod
using CLIMA.StrongStabilityPreservingRungeKuttaMethod
using CLIMA.ODESolvers
using CLIMA.GenericCallbacks
using CLIMA.Vtk
using LinearAlgebra
using StaticArrays
using Logging, Printf, Dates
using Random

@static if haspkg("CUDAnative")
  using CUDAdrv
  using CUDAnative
  using CuArrays
  @assert VERSION >= v"1.2-pre.25"
  CuArrays.allowscalar(false)
  const ArrayTypes = (CuArray,)
else
  const ArrayTypes = (Array, )
end

const uid, vid, wid = 1:3
const radians = true
const γ_exact = 7 // 5

if !@isdefined integration_testing
  const integration_testing =
  parse(Bool, lowercase(get(ENV,"JULIA_CLIMA_INTEGRATION_TESTING","false")))
  using Random
end

# preflux computation: NOT needed for this test
@inline function preflux(Q, _...)
  γ::eltype(Q) = γ_exact
  @inbounds ρ = Q[1]
  ρinv = 1 / ρ
  u, v, w, P = 0, 0, 0, 0
  (P, u, v, w, ρinv)
end

#{{{ advectionflux
advectionflux!(F, Q, QV, aux, t) = advectionflux!(F, Q, QV, aux, t,
                                                  preflux(Q)...)
@inline function advectionflux!(F,Q,QV,aux,t,P,u,v,w,ρinv)
  @inbounds begin
    u,v,w = aux[uid], aux[vid], aux[wid]
    ρ=Q[1]
    F[1,1], F[2,1], F[3,1]=u*ρ, v*ρ, w*ρ
  end
end
#}}} advectionflux

#{{{ wavespeed
@inline function wavespeed(n, Q, vel, t...)
  # abs(dot(vel,n)) # FIXME: Nice to do this, but breaks with cassette
  abs(vel[1] * n[1] + vel[2] * n[2] + vel[3] * n[3])
end
#}}} wavespeed

#{{{ Cartesian->Spherical
@inline function cartesian_to_spherical(x,y,z,radians)
  # Conversion Constants
  if radians
    c=1.0
  else
    c=180/π
  end
  λ_max=2π*c
  λ_min=0*c
  ϕ_max=+0.5*π*c
  ϕ_min=-0.5*π*c

  # Conversion functions
  r = hypot(x,y,z)
  λ=atan(y,x)*c
  ϕ=asin(z/r)*c
  return (r, λ, ϕ)
end
#}}} Cartesian->Spherical

#{{{ velocity initial condition
@inline function velocity_init!(vel, x, y, z)
  @inbounds begin
    DFloat = eltype(vel)
    (r, λ, ϕ) = cartesian_to_spherical(x,y,z,radians)
    # w = 2 * DFloat(π) * cos(ϕ) # Case 1 -> shear flow
    w = 2 * DFloat(π) * cos(ϕ) * r # Case 2 -> solid body flow
    uλ, uϕ = w, 0
    vel[uid] = -uλ*sin(λ) - uϕ*cos(λ)*sin(ϕ)
    vel[vid] = +uλ*cos(λ) - uϕ*sin(λ)*sin(ϕ)
    vel[wid] = +uϕ*cos(ϕ)
  end
end
#}}} velocity initial condition

# initial condition
function advection_sphere!(Q, t, x, y, z, vel)
  DFloat = eltype(Q)
  rc=1.5
  (r, λ, ϕ) = cartesian_to_spherical(x,y,z,radians)
  ρ = exp(-((3λ)^2 + (3ϕ)^2))

  if integration_testing
    @inbounds Q[1] = ρ
  else
    @inbounds Q[1], vel[1], vel[2], vel[3] = 10+rand(), rand(), rand(), rand()
  end
end

#{{{ Main
function main(mpicomm, DFloat, topl, N, timeend, ArrayType, dt, ti_method)
  grid = DiscontinuousSpectralElementGrid(topl,
                                          FloatType = DFloat,
                                          DeviceArray = ArrayType,
                                          polynomialorder = N,
                                          meshwarp = Topologies.cubedshellwarp)

  #{{{ numerical fluxex
  numflux!(x...) = NumericalFluxes.rusanov!(x..., advectionflux!,
                                            wavespeed, preflux)

  # zero flux at the boundaries: not entirely accurate but good enough
  function numbcflux!(F, _...)
    for s = 1:length(F)
      F[s] = 0
    end
  end

  # Define Spatial Discretization
  spacedisc=DGBalanceLaw(grid = grid,
                         length_state_vector = 1,
                         flux! = advectionflux!,
                         numerical_flux! = numflux!,
                         numerical_boundary_flux! = numbcflux!,
                         auxiliary_state_length = 3,
                         auxiliary_state_initialization! = velocity_init!)

  # Initial Condition
  initialcondition(Q, x...) = advection_sphere!(Q, DFloat(0), x...)
  Q = MPIStateArray(spacedisc, initialcondition)

  # Store Initial Condition as Exact Solution
  Qe = copy(Q)

  # Define Time-Integration Method
  if ti_method == "LSRK"
    TimeIntegrator = LowStorageRungeKutta(spacedisc, Q; dt = dt, t0 = 0)
  elseif ti_method == "SSP33"
    TimeIntegrator = StrongStabilityPreservingRungeKutta33(spacedisc, Q;
                                                           dt = dt, t0 = 0)
  elseif ti_method == "SSP34"
    TimeIntegrator = StrongStabilityPreservingRungeKutta34(spacedisc, Q;
                                                           dt = dt, t0 = 0)
  end

  #------------Set Callback Info--------------------------------#
  # Set up the information callback
  starttime = Ref(now())
  cbinfo = GenericCallbacks.EveryXWallTimeSeconds(10, mpicomm) do (s=false)
    if s
      starttime[] = now()
    else
      @info @sprintf("""Update
                     simtime = %.16e
                     runtime = %s
                     Δmass   = %.16e""",
                     ODESolvers.gettime(TimeIntegrator),
                     Dates.format(convert(Dates.DateTime,
                                          Dates.now()-starttime[]),
                                  Dates.dateformat"HH:MM:SS"),
                     abs(weightedsum(Q) - weightedsum(Qe)) / weightedsum(Qe))
    end
    nothing
  end

  # Set up the information callback
  cbmass = GenericCallbacks.EveryXSimulationSteps(1000) do
    @info @sprintf """Update
    Δmass   = %.16e""" abs(weightedsum(Q) - weightedsum(Qe)) / weightedsum(Qe)
  end

  step = [0]
  mkpath("vtk")
  cbvtk = GenericCallbacks.EveryXSimulationSteps(1000) do (init=false)
    outprefix = @sprintf("vtk/advection_sphere_%dD_mpirank%04d_step%04d",
                         3, MPI.Comm_rank(mpicomm), step[1])
    @debug "doing VTK output" outprefix
    writevtk(outprefix, Q, spacedisc, ("ρ", ))
    step[1] += 1
    nothing
  end
  #------------Set Callback Info--------------------------------#

  # Perform Time-Integration
  solve!(Q, TimeIntegrator; timeend=timeend, callbacks=(cbinfo, cbmass, cbvtk))

  # Print some end of the simulation information
  if integration_testing
    error = euclidean_distance(Q, Qe) / norm(Qe)
    Δmass = abs(weightedsum(Q) - weightedsum(Qe)) / weightedsum(Qe)
    @info @sprintf """Finished
    error = %.16e
    Δmass = %.16e
    """ error Δmass
  else
    error = euclidean_distance(Q, Qe) / norm(Qe)
    Δmass = abs(weightedsum(Q) - weightedsum(Qe)) / weightedsum(Qe)
    @info @sprintf """Finished
    error = %.16e
    Δmass = %.16e
    """ error Δmass
  end

  # return diagnostics
  return (error, Δmass)
end
#}}} Main

#{{{ Run Script
function run(mpicomm, Nhorizontal, Nvertical, N, timeend, DFloat, dt, ti_method,
             ArrayType)
  Rrange=range(DFloat(1); length=Nvertical+1, stop=2)
  topl = StackedCubedSphereTopology(mpicomm,Nhorizontal,Rrange; boundary=(1,1))
  (error, Δmass) = main(mpicomm, DFloat, topl, N, timeend, ArrayType, dt,
                        ti_method)
end
#}}} Run Script

#{{{ Run Program
using Test
let
  MPI.Initialized() || MPI.Init()
  Sys.iswindows() || (isinteractive() && MPI.finalize_atexit())
  mpicomm=MPI.COMM_WORLD

  ll = uppercase(get(ENV, "JULIA_LOG_LEVEL", "INFO"))
  loglevel = ll == "DEBUG" ? Logging.Debug :
  ll == "WARN"  ? Logging.Warn  :
  ll == "ERROR" ? Logging.Error : Logging.Info
  logger_stream = MPI.Comm_rank(mpicomm) == 0 ? stderr : devnull
  global_logger(ConsoleLogger(logger_stream, loglevel))
  @static if haspkg("CUDAnative")
    device!(MPI.Comm_rank(mpicomm) % length(devices()))
  end

  # Perform Integration Testing for three different grid resolutions
  ti_method = "SSP34" #LSRK or SSP
  if integration_testing
    timeend = 1
    numelem = (2, 2) #(Nhorizontal,Nvertical)
    N = 4

    expected_error = Array{Float64}(undef, 3) # h-refinement levels lvl
    expected_error[1] = 2.1747884619563834e-01 # Ne=2
    expected_error[2] = 1.2161683394578116e-02 # Ne=4
    expected_error[3] = 2.2529850289795472e-04 # Ne=8
    expected_mass = Array{Float64}(undef, 3) # h-refinement levels lvl
    expected_mass[1] = 2.1031020568795386e-15 # Ne=2
    expected_mass[2] = 7.4279250361339182e-15 # Ne=4
    expected_mass[3] = 6.7271491130202594e-14 # Ne=8
    lvls = length(expected_error)

    for ArrayType in ArrayTypes
      dt=1e-2*5 # stable dt for N=4 and Ne=5
      for DFloat in (Float64,) # Float32)
        err = zeros(DFloat, lvls)
        mass= zeros(DFloat, lvls)
        for l = 1:lvls
          Nhorizontal = 2^(l-1) * numelem[1]
          Nvertical   = 2^(l-1) * numelem[2]
          dt=dt/Nhorizontal
          nsteps = ceil(Int64, timeend / dt)
          dt = timeend / nsteps
          @info @sprintf """Run Configuration
          Nhorizontal = %d
          Nvertical   = %d
          N           = %d
          dt          = %.16e
          nsteps       = %d
          """ Nhorizontal Nvertical N dt nsteps
          @info (ArrayType, DFloat)
          (err[l], mass[l]) = run(mpicomm, Nhorizontal, Nvertical, N, timeend,
                                  DFloat, dt, ti_method, ArrayType)
          @test err[l]  ≈ DFloat(expected_error[l])
          #                @test mass[l] ≈ DFloat(expected_mass[l])
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
  else
    timeend = 1
    numelem = (2, 2) #(Nhorizontal,Nvertical)
    N = 4
    dt=1e-2*5 # stable dt for N=4 and Ne=5

    Nhorizontal = numelem[1]
    Nvertical   = numelem[2]
    dt=dt/Nhorizontal
    nsteps = ceil(Int64, timeend / dt)
    numproc=MPI.Comm_size(mpicomm)

    expected_error = Array{Float64}(undef, 2)
    expected_error[1] = 2.1881282358529316e-02
    expected_error[2] = 2.1890633646296072e-02
    expected_mass = Array{Float64}(undef, 2)
    expected_mass[1] = 2.0308668409792276e-15
    expected_mass[2] = 2.0329061975125196e-15
    for ArrayType in ArrayTypes
      for DFloat in (Float64,) # Float32)
        Random.seed!(0)
        @info @sprintf """Run Configuration
        Nhorizontal = %d
        Nvertical   = %d
        N           = %d
        dt          = %.16e
        nsteps       = %d
        """ Nhorizontal Nvertical N dt nsteps
        @info (ArrayType, DFloat)
        (error, mass) = run(mpicomm, Nhorizontal, Nvertical, N, timeend, DFloat,
                            dt, ti_method, ArrayType)
        @test error ≈ DFloat(expected_error[numproc])
        #            @test mass ≈ DFloat(expected_mass[numproc])
      end
    end
  end
  # Perform Integration Testing for three different grid resolutions

  #=
  # This snippet of code allows one to run just one instance/configuration.
  # Before running this, Comment the Integration Testing block above
  DFloat = Float64
  N=4
  ArrayType = Array
  dt=1e-2*5 # stable dt for N=4 and Ne=5
  ti_method = "SSP34" #LSRK or SSP
  timeend=1.0
  Nhorizontal = 2 # number of horizontal elements per face of cubed-sphere grid
  Nvertical = 2 # number of horizontal elements per face of cubed-sphere grid
  dt=dt/Nhorizontal
  nsteps = ceil(Int64, timeend / dt)
  dt = timeend / nsteps
  (error, Δmass) = run(mpicomm, Nhorizontal, Nvertical, N, timeend, DFloat, dt,
                       ti_method, ArrayType)
  =#

end # Test

isinteractive() || MPI.Finalize()

# nothing
