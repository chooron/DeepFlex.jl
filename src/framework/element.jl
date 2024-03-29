# Element Methods
function get_element_info(elements::Vector{E}) where {E<:AbstractElement}
    input_names = Vector{Symbol}()
    output_names = Vector{Symbol}()
    state_names = Vector{Symbol}()
    param_names = Vector{Symbol}()

    for ele in elements
        union!(input_names, setdiff(ele.input_names, output_names))
        union!(output_names, ele.output_names)
        union!(param_names, ele.param_names)
        if ele isa ODEElement
            union!(state_names, ele.state_names)
        end
    end
    input_names, output_names, state_names, param_names
end

function get_output(ele::AbstractElement, input::NamedTuple)
    return nothing
end

"""
SimpleElement

SimpleElement是由多个AbstractFlux组成，无中间状态，对应RRMG的一些模型
"""
struct SimpleElement <: AbstractElement
    name::Symbol

    # attribute
    input_names::Vector{Symbol}
    output_names::Vector{Symbol}
    param_names::Vector{Symbol}

    # functions
    funcs::Vector{AbstractFlux}
end

function SimpleElement(
    ; name::Symbol,
    funcs::Vector{F},
) where {F<:AbstractFlux}

    input_names, output_names, param_names = get_func_infos(funcs)

    return SimpleElement(
        name,
        input_names,
        output_names,
        param_names,
        funcs
    )
end

function get_output(ele::SimpleElement; input::NamedTuple, parameters::NamedTuple)
    fluxes = input
    for func in ele.funcs
        fluxes = merge(fluxes, func(fluxes, parameters))
    end
    return fluxes[ele.output_names]
end

"""
ODEElement

ODEElement是由多个AbstractFlux组成，有中间状态，求解方式包含continuous和discrete两种
"""
struct ODEElement <: AbstractElement
    name::Symbol

    # attribute
    input_names::Vector{Symbol}
    output_names::Vector{Symbol}
    param_names::Vector{Symbol}
    state_names::Vector{Symbol}

    # functions
    funcs::Vector{AbstractFlux}
    dfuncs::Vector{AbstractFlux}
end

function ODEElement(
    ; name::Symbol,
    funcs::Vector{F},
    dfuncs::Vector{F},
) where {F<:AbstractFlux}
    # combine the info of func and d_func
    input_names1, output_names, param_names1 = get_func_infos(funcs)
    input_names2, state_names, param_names2 = get_dfunc_infos(dfuncs)
    # 避免一些中间变量混淆为输入要素
    setdiff!(input_names2, output_names)
    # 合并两种func的输入要素
    input_names = union(input_names1, input_names2)
    # 删除输入要素的状态要素
    setdiff!(input_names, state_names)
    # 合并两种类型函数的参数
    param_names = union(param_names1, param_names2)

    return ODEElement(
        name,
        input_names,
        output_names,
        param_names,
        state_names,
        funcs,
        dfuncs
    )
end

function set_solver!(ele::ODEElement, solver::AbstractSolver)
    setproperty!(ele, :solver, solver)
end

function pretrain!(ele::ODEElement; input::NamedTuple, train_config...)
    for func in ele.funcs
        if isa(func, LuxNNFunc)
            pretrain!(func, input=input, train_config...)
        end
    end
end

function solve_prob(
    ele::ODEElement;
    input::NamedTuple,
    parameters::NamedTuple,
    init_states::NamedTuple,
    solver::AbstractSolver,
)
    # fit interpolation functions
    itp_dict = namedtuple(ele.input_names, [LinearInterpolation(input[nm], input[:time], extrapolate=true) for nm in ele.input_names])
    # itp_dict = Dict(nm => LinearInterpolation(input[nm], input[:time]) for nm in [:temp,:lday,:prcp])
    # filter(isa(LagFlux), ele.funcs) do func
    #     init!(func, parameters)
    # end
    # solve the problem
    function singel_ele_ode_func!(du, u, p, t)
        tmp_input = namedtuple(ele.input_names, [itp_dict[nm](t) for nm in ele.input_names])
        tmp_states = namedtuple(ele.state_names, u)
        tmp_fluxes = get_output(ele, input=tmp_input, states=tmp_states, parameters=parameters)
        for (idx, dfunc) in enumerate(ele.dfuncs)
            tmp_du = dfunc(tmp_fluxes, parameters)[dfunc.output_names]
            du[idx] = tmp_du
        end
    end
    prob = ODEProblem(singel_ele_ode_func!, collect(init_states), (input[:time][1], input[:time][end]))
    # return solved result
    solver(prob, init_states, (saveat=input[:time],))
end

function get_output(
    ele::ODEElement;
    input::NamedTuple,
    states::NamedTuple,
    parameters::NamedTuple
)::NamedTuple
    fluxes = merge(input, states)
    for func in ele.funcs
        fluxes = merge(fluxes, func(fluxes, parameters))
    end
    return fluxes
end

"""
LAGElement
"""
struct LAGElement <: AbstractElement
    name::Symbol

    # attribute
    input_names::Vector{Symbol}
    output_names::Vector{Symbol}

    # parameters names
    param_names::Vector{Symbol}
    lagtime_dict::Dict{Symbol,Symbol}

    # func
    lag_func::Dict{Symbol,Function}
    step_func::Function
end

function LAGElement(
    ; name::Symbol,
    lagtime_dict::Dict{Symbol,Symbol},
    lag_func::Dict{Symbol,F}
) where {F<:Function}

    step_func = DEFAULT_SMOOTHER

    param_names = Vector{Symbol}()
    for v in values(lagtime_dict)
        union!(param_names, [v])
    end

    input_names = collect(keys(lag_func))

    LAGElement(
        name,
        input_names,
        input_names,
        param_names,
        lagtime_dict,
        lag_func,
        step_func,
    )
end

function preprocess_parameters(ele::LAGElement; parameters::NamedTuple)
    # init lag states
    lag_states = namedtuple(ele.input_names, [zeros(Int(ceil(parameters[ele.lagtime_dict[nm]]))) for nm in ele.input_names])

    # build weight
    lag_weights = namedtuple(ele.input_names,
        [[ele.lag_func[nm](T(i), T(parameters[ele.lagtime_dict[nm]]), ele.step_func) -
          ele.lag_func[nm](T(i - 1), T(parameters[ele.lagtime_dict[nm]]), ele.step_func)
          for i in 1:(ceil(parameters[ele.lagtime_dict[nm]])|>Int)] for nm in ele.input_names])

    lag_states, lag_weights
end

function solve_lag(input::NamedTuple, lag_states::NamedTuple, lag_weights::NamedTuple)
    max_weight_len = maximum([length(lag_weights[k]) for k in keys(lag_weights)])
    max_input_len = maximum([length(input[k]) for k in keys(input)])

    output = Dict(k => zeros(max_input_len, max_weight_len) for k in keys(input))

    for k in keys(output)
        w, ls, ip = lag_weights[k], lag_states[k], input[k]
        for t in 1:max_input_len
            updated_state = ls .+ ip[t] .* w
            output[k][t, 1:length(w)] .= updated_state
            ls = vcat(updated_state[2:end], 0)
        end
    end
    return output
end

function get_output(ele::LAGElement; input::NamedTuple, parameters::NamedTuple)
    lag_states, lag_weights = preprocess_parameters(ele, parameters=parameters)

    input = input[ele.input_names]
    solved_state = solve_lag(input, lag_states, lag_weights)

    for k in ele.input_names
        solved_state[k][end, 1:end-1] = solved_state[k][end, 2:end]
        solved_state[k][end, end] = 0
        solved_state[k][end, :]
    end

    # lag element don't need save states
    # updated_lag_states = NamedTuple(namedtuple(ele.input_names, [solved_state[k][end, :] for k in ele.input_names]))
    namedtuple(ele.input_names, [solved_state[k][:, 1] for k in ele.input_names])
end