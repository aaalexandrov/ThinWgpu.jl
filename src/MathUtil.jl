using StaticArrays
using LinearAlgebra

const vec2f = SVector{2, Float32}
const vec3f = SVector{3, Float32}
const vec4f = SVector{4, Float32}
const mat3f = SMatrix{3, 3, Float32}
const mat4f = SMatrix{4, 4, Float32}

function rot(angle::T, axis::SVector{3, T})::SMatrix{3, 3, T} where T
    u = normalize(axis)
    s, c = sincos(angle)
    oc = 1 - c
    SMatrix{3, 3, T}(
        u.x^2*oc+c      , u.x*u.y*oc+u.z*s, u.x*u.z*oc-u.y*s,
        u.x*u.y*oc-u.z*s, u.y^2*oc+c      , u.y*u.z*oc+u.x*s,
        u.x*u.z*oc+u.y*s, u.y*u.z*oc-u.x*s, u.z^2*oc+c
    )
end

function angle_axis(m::SMatrix{3, 3, T})::Tuple{T, SVector{3, T}} where T
	t = m[1,1] + m[2,2] + m[3,3]
	anglecos = (t-1)/2
	anglecos >= 1 - eps(T) && return zero(T), T[0,0,1]
	axis = SVector{3, T}(m[3,2] - m[2,3], m[1,3] - m[3,1], m[2,1] - m[1,2])
	if anglecos <= -1 + eps(T)
		squares = SVector{3, T}((m[1,1]+1)/2, (m[2,2]+1)/2, (m[3,3]+1)/2)
		axis /= 4
		i = argmax(squares)
		if i == 1
			axis = SVector{3, T}(squares[i], m[2,1] + m[1,2], m[1,3] + m[3,1])
		elseif i == 2
			axis = SVector{3, T}(m[2,1] + m[1,1], squares[i], m[3,2] + m[2,3])
		else
			@assert(i == 3)
			axis = SVector{3, T}(m[1,3] + m[3,1], m[3,2] + m[2,3], squares[i])
		end
		maxel = sqrt(squares[i])
		axis /= maxel
		return T(pi), axis
	end
	axislen = norm(axis)
	anglesin = axislen/2
	angle = atan(anglesin, anglecos)
	axis /= axislen
	angle, axis
end

function xform_compose(pos::SVector{3, T}, rot::SMatrix{3, 3, T}, scale::T)::SMatrix{4, 4, T} where T
	vcat(hcat(rot * scale, pos), SMatrix{1, 4, T}(0, 0, 0, 1))
end

function xform_decompose(m::SMatrix{4, 4, T})::Tuple{SVector{3, T}, SMatrix{3, 3, T}, T} where T
	rot = m[1:3, 1:3]
	scale = norm(rot[:, 3])
	pos = m[1:3, 4]
	pos, rot / scale, scale
end

function perspective(wtohRatio::T, vfov::T, near::T, far::T)::SMatrix{4, 4, T} where T
	rcpTan = T(1) / tan(vfov)
	SMatrix{4, 4, T}(
		rcpTan / wtohRatio, 0     , 0                   , 0,
		0                 , rcpTan, 0                   , 0,
		0                 , 0     , far/(far-near)      , 1,
		0                 , 0     , -far*near/(far-near), 0
	)
end

function ortho(left::T, right::T, top::T, bottom::T, near::T, far::T)::SMatrix{4, 4, T} where T
	SMatrix{4, 4, T}(
		2/(right-left)            , 0                         , 0               , 0,
		0                         , 2/(top-bottom)            , 0               , 0,
		0                         , 0                         , 1/(far-near)    , 0,
		-(right+left)/(right-left), -(top+bottom)/(top-bottom), -near*(far-near), 1
	)
end