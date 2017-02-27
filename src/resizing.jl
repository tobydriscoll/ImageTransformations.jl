"""
    restrict(img[, region]) -> imgr

Reduce the size of `img` by two-fold along the dimensions listed in
`region`, or all spatial coordinates if `region` is not specified.  It
anti-aliases the image as it goes, so is better than a naive summation
over 2x2 blocks.

See also [`imresize`](@ref).
"""
restrict(img::AbstractArray, ::Tuple{}) = img

function restrict(A::AbstractArray, region::Union{Dims,Vector{Int}} = coords_spatial(A))
    for dim in region
        A = restrict(A, dim)
    end
    A
end

function restrict{T,N}(A::AbstractArray{T,N}, dim::Integer)
    if size(A, dim) <= 2
        return A
    end
    newsz = ntuple(i->i==dim?restrict_size(size(A,dim)):size(A,i), Val{N})
    # FIXME: The following line fails for interpolations because
    # interpolations can be accessed linearily A[i].
    #    out = Array{typeof(A[1]/4+A[2]/2),N}(newsz)
    out = Array{typeof(first(A)/4+first(A)/2),N}(newsz)
    restrict!(out, A, dim)
    out
end

# out should have efficient linear indexing
for N = 1:5
    @eval begin
        function restrict!{T}(out::AbstractArray{T,$N}, A::AbstractArray, dim)
            if isodd(size(A, dim))
                half = convert(eltype(T), 0.5)
                quarter = convert(eltype(T), 0.25)
                indx = 0
                if dim == 1
                    @inbounds @nloops $N i d->(d==1 ? (1:1) : (1:size(A,d))) d->(j_d = d==1 ? i_d+1 : i_d) begin
                        nxt = convert(T, @nref $N A j)
                        out[indx+=1] = half*(@nref $N A i) + quarter*nxt
                        for k = 3:2:size(A,1)-2
                            prv = nxt
                            i_1 = k
                            j_1 = k+1
                            nxt = convert(T, @nref $N A j)
                            out[indx+=1] = quarter*(prv+nxt) + half*(@nref $N A i)
                        end
                        i_1 = size(A,1)
                        out[indx+=1] = quarter*nxt + half*(@nref $N A i)
                    end
                else
                    strd = stride(out, dim)
                    # Must initialize the i_dim==1 entries with zero
                    @nexprs $N d->sz_d=d==dim?1:size(out,d)
                    @nloops $N i d->(1:sz_d) begin
                        (@nref $N out i) = zero(T)
                    end
                    stride_1 = 1
                    @nexprs $N d->(stride_{d+1} = stride_d*size(out,d))
                    @nexprs $N d->offset_d = 0
                    ispeak = true
                    @inbounds @nloops $N i d->(d==1?(1:1):(1:size(A,d))) d->(if d==dim; ispeak=isodd(i_d); offset_{d-1} = offset_d+(div(i_d+1,2)-1)*stride_d; else; offset_{d-1} = offset_d+(i_d-1)*stride_d; end) begin
                        indx = offset_0
                        if ispeak
                            for k = 1:size(A,1)
                                i_1 = k
                                out[indx+=1] += half*(@nref $N A i)
                            end
                        else
                            for k = 1:size(A,1)
                                i_1 = k
                                tmp = quarter*(@nref $N A i)
                                out[indx+=1] += tmp
                                out[indx+strd] = tmp
                            end
                        end
                    end
                end
            else
                threeeighths = convert(eltype(T), 0.375)
                oneeighth = convert(eltype(T), 0.125)
                indx = 0
                if dim == 1
                    z = convert(T, zero(first(A)))
                    @inbounds @nloops $N i d->(d==1 ? (1:1) : (1:size(A,d))) d->(j_d = i_d) begin
                        c = d = z
                        for k = 1:size(out,1)-1
                            a = c
                            b = d
                            j_1 = 2*k
                            i_1 = j_1-1
                            c = convert(T, @nref $N A i)
                            d = convert(T, @nref $N A j)
                            out[indx+=1] = oneeighth*(a+d) + threeeighths*(b+c)
                        end
                        out[indx+=1] = oneeighth*c+threeeighths*d
                    end
                else
                    fill!(out, zero(T))
                    strd = stride(out, dim)
                    stride_1 = 1
                    @nexprs $N d->(stride_{d+1} = stride_d*size(out,d))
                    @nexprs $N d->offset_d = 0
                    peakfirst = true
                    @inbounds @nloops $N i d->(d==1?(1:1):(1:size(A,d))) d->(if d==dim; peakfirst=isodd(i_d); offset_{d-1} = offset_d+(div(i_d+1,2)-1)*stride_d; else; offset_{d-1} = offset_d+(i_d-1)*stride_d; end) begin
                        indx = offset_0
                        if peakfirst
                            for k = 1:size(A,1)
                                i_1 = k
                                tmp = @nref $N A i
                                out[indx+=1] += threeeighths*tmp
                                out[indx+strd] += oneeighth*tmp
                            end
                        else
                            for k = 1:size(A,1)
                                i_1 = k
                                tmp = @nref $N A i
                                out[indx+=1] += oneeighth*tmp
                                out[indx+strd] += threeeighths*tmp
                            end
                        end
                    end
                end
            end
        end
    end
end

restrict_size(len::Integer) = isodd(len) ? (len+1)>>1 : (len>>1)+1

# imresize
imresize(original::AbstractArray, dim1, dimN...) = imresize(original, (dim1,dimN...))

function imresize{T,N}(original::AbstractArray{T,N}, short_size::NTuple)
    len_short = length(short_size)
    new_size = ntuple(i -> (i > len_short ? size(original,i) : short_size[i]), N)
    imresize(original, new_size)
end

"""
    imresize(img, sz) -> imgr

Change `img` to be of size `sz`. This interpolates the values at
sub-pixel locations. If you are shrinking the image, you risk aliasing
unless you low-pass filter `img` first. For example:

    σ = map((o,n)->0.75*o/n, size(img), sz)
    kern = KernelFactors.gaussian(σ)   # from ImageFiltering
    imgr = imresize(imfilter(img, kern, NA()), sz)

See also [`restrict`](@ref).
"""
function imresize{T,N}(original::AbstractArray{T,N}, new_size::NTuple{N})
    Tnew = imresize_type(first(original))
    if size(original) == new_size
        copy!(similar(original, Tnew), original)
    else
        imresize!(similar(original, Tnew, new_size), original)
    end
end

# To choose the output type, rather than forcing everything to
# Float64 by multiplying by 1.0, we exploit the fact that the scale
# changes correspond to integer ratios.  We mimic ratio arithmetic
# without actually using Rational (which risks promoting to a
# Rational type, too slow for image processing).
imresize_type(c::Colorant) = base_colorant_type(c){eltype(imresize_type(Gray(c)))}
imresize_type(c::Gray) = Gray{imresize_type(gray(c))}
imresize_type(c::FixedPoint) = typeof(c)
imresize_type(c) = typeof((c*1)/1)

function imresize!{T,S,N}(resized::AbstractArray{T,N}, original::AbstractArray{S,N})
    itp = interpolate(original, BSpline(Linear()), OnGrid())
    imresize!(resized, itp)
end

function imresize!{T,S,N}(resized::AbstractArray{T,N}, original::AbstractInterpolation{S,N})
    # Define the equivalent of an affine transformation for mapping
    # locations in `resized` to the corresponding position in
    # `original`. We take the viewpoint that a pixel at `i, j` is a
    # sensor that *integrates* the intensity over an area spanning
    # `i±0.5, j±0.5` (this is a good model of how a camera pixel
    # actually works). We then map the *outer corners* of the two
    # images to each other, i.e., in typical cases
    #     (0.5, 0.5) -> (0.5, 0.5)  (outer corner, top left)
    #     size(resized)+0.5 -> size(original)+0.5  (outer corner, lower right)
    # This ensures that both images cover exactly the same area.
    Ro, Rr = CartesianRange(indices(original)), CartesianRange(indices(resized))
    sf = map(/, (last(Ro)-first(Ro)+1).I, (last(Rr)-first(Rr)+1).I) # +1 for outer corners
    offset = map((io,ir,s)->io - 0.5 - s*(ir-0.5), first(Ro).I, first(Rr).I, sf)
    if all(x->x >= 1, sf)
        @inbounds for I in Rr
            I_o = map3((i,s,off)->s*i+off, I.I, sf, offset)
            resized[I] = original[I_o...]
        end
    else
        @inbounds for I in Rr
            I_o = clampR(map3((i,s,off)->s*i+off, I.I, sf, offset), Ro)
            resized[I] = original[I_o...]
        end
    end
    resized
end

# map isn't optimized for 3 tuple-arguments, so do it here
@inline map3(f, a, b, c) = (f(a[1], b[1], c[1]), map3(f, tail(a), tail(b), tail(c))...)
@inline map3(f, ::Tuple{}, ::Tuple{}, ::Tuple{}) = ()

function clampR{N}(I::NTuple{N}, R::CartesianRange{CartesianIndex{N}})
    map3(clamp, I, first(R).I, last(R).I)
end