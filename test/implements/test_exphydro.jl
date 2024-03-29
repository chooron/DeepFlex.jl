# import lib
using CSV
using DataFrames
using CairoMakie
using BenchmarkTools

# test exphydro model
include("../../src/DeepFlex.jl")

# load data
file_path = "data/camels/01013500.csv"
data = CSV.File(file_path);
df = DataFrame(data);
lday_vec = df[1:10000, "dayl(day)"]
prcp_vec = df[1:10000, "prcp(mm/day)"]
temp_vec = df[1:10000, "tmean(C)"]
flow_vec = df[1:10000, "flow(mm)"]

# build model
f, Smax, Qmax, Df, Tmax, Tmin = 0.01674478, 1709.461015, 18.46996175, 2.674548848, 0.175739196, -2.092959084
parameters = (f=f, Smax=Smax, Qmax=Qmax, Df=Df, Tmax=Tmax, Tmin=Tmin)
init_states = (snowwater=0.0, soilwater=1303.004248)

model = DeepFlex.ExpHydro(name=:exphydro)

inputs = (prcp=prcp_vec, lday=lday_vec, temp=temp_vec, time=1:1:length(lday_vec))
result = DeepFlex.get_output(model, input=inputs, parameters=parameters, init_states=init_states);
model_states = result[model.state_names]
result_df = DataFrame(Dict(k => result[k] for k in keys(result)))

# plot result
fig = Figure(size=(400, 300))
ax = CairoMakie.Axis(fig[1, 1], title="predict results", xlabel="time", ylabel="flow(mm)")
x = range(1, 10000, length=10000)
lines!(ax, x, flow_vec, color=:red)
lines!(ax, x, result_df[!, :flow], color=:blue)
fig

@btime DeepFlex.get_output(model, input=inputs, parameters=parameters, init_states=init_states);