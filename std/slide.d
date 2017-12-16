import std.range, std.stdio, std.typecons;

/**
A fixed-sized sliding window iteration
of size `windowSize` over a `source` range by a custom `stepSize`.

The `Source` range must be at least an `ForwardRange` and
the `windowSize` must be greater than zero.

For `windowSize = 1` it splits the range into single element groups (aka `unflatten`)
For `windowSize = 2` it is similar to `zip(source, source.save.dropOne)`.

Params:
    f = If the last element `Yes.withPartial` with fewer
        elements than `windowSize` should be be ignored (withPartial)
    r = Range from which the slide will be selected
    windowSize = Sliding window size
    stepSize = Steps between the windows (by default 1)

Returns: Range of all sliding windows with propagated bi-directionality,
         forwarding, random access, and slicing.

Note: Due to performance concerns, bi-directionality is only forwarded for
      $(REF hasSlicing, std,range,primitives) and $(REF hasLength, std,range,primitives).

See_Also: $(LREF chunks)
*/
auto slide(Flag!"withPartial" f = Yes.withPartial,
            Source)(Source source, size_t windowSize, size_t stepSize = 1)
    if (isForwardRange!Source)
{
    return Slides!(f, Source)(source, windowSize, stepSize);
}

private struct Slides(Flag!"withPartial" withPartial = Yes.withPartial, Source)
    if (isForwardRange!Source)
{
private:
    Source source;
    size_t windowSize;
    size_t stepSize;

    static if (hasLength!Source)
    {
        enum needsEndTracker = false;
    }
    else
    {
        // If there's no information about the length, track needs to be kept manually
        Source nextSource;
        enum needsEndTracker = true;
    }

    bool _empty;

    static if (hasSlicing!Source)
        enum hasSliceToEnd = hasSlicing!Source && is(typeof(Source.init[0 .. $]) == Source);

    static if (withPartial)
        bool hasShownPartialBefore;

public:
    /// Standard constructor
    this(Source source, size_t windowSize, size_t stepSize)
    {
        assert(windowSize > 0, "windowSize must be greater than zero");
        assert(stepSize > 0, "stepSize must be greater than zero");
        this.source = source;
        this.windowSize = windowSize;
        this.stepSize = stepSize;

        static if (needsEndTracker)
        {
            // `nextSource` is used to "look one step into the future" and check for the end
            // this means `nextSource` is advanced by `stepSize` on every `popFront`
            nextSource = source.save.drop(windowSize);
        }

        if (source.empty)
        {
            _empty = true;
            return;
        }

        static if (withPartial)
        {
            static if (needsEndTracker)
            {
                if (nextSource.empty)
                    hasShownPartialBefore = true;
            }
            else
            {
                if (source.length <= windowSize)
                    hasShownPartialBefore = true;
            }

        }
        else
        {
            // empty source range is needed, s.t. length, slicing etc. works properly
            static if (needsEndTracker)
            {
                if (nextSource.empty)
                     _empty = true;
            }
            else
            {
                if (source.length < windowSize)
                     _empty = true;
            }
        }
    }

    /// Forward range primitives. Always present.
    @property auto front()
    {
        assert(!empty, "Attempting to access front on an empty slide.");
        static if (hasSlicing!Source && hasLength!Source)
        {
            static if (withPartial)
            {
                import std.algorithm.comparison : min;
                return source[0 .. min(windowSize, source.length)];
            }
            else
            {
                assert(windowSize <= source.length, "The last element is smaller than the current windowSize.");
                return source[0 .. windowSize];
            }
        }
        else
        {
            static if (withPartial)
                return source.save.take(windowSize);
            else
                return source.save.takeExactly(windowSize);
        }
    }

    /// Ditto
    void popFront()
    {
        assert(!empty, "Attempting to call popFront() on an empty slide.");
        source.popFrontN(stepSize);

        if (source.empty)
        {
            _empty = true;
            return;
        }

        static if (withPartial)
        {
            if (hasShownPartialBefore)
                _empty = true;
        }

        static if (needsEndTracker)
        {
            // Check the upcoming slide
            auto poppedElements = nextSource.popFrontN(stepSize);
            static if (withPartial)
            {
                if (poppedElements < stepSize || nextSource.empty)
                    hasShownPartialBefore = true;
            }
            else
            {
                if (poppedElements < stepSize)
                    _empty = true;
            }
        }
        else
        {
            static if (withPartial)
            {
                if (source.length <= windowSize)
                    hasShownPartialBefore = true;
            }
            else
            {
                if (source.length < windowSize)
                    _empty = true;
            }
        }
    }

    static if (!isInfinite!Source)
    {
        /// Ditto
        @property bool empty() const
        {
            return _empty;
        }
    }
    else
    {
        // undocumented
        enum empty = false;
    }

    /// Ditto
    @property typeof(this) save()
    {
        return typeof(this)(source.save, windowSize, stepSize);
    }

    static if (hasLength!Source)
    {
        // gaps between the last element and the end of the range
        private size_t gap()
        {
            /*
            * Note:
            * - In the following `end` is the exclusive end as used in opSlice
            * - For the trivial case with `stepSize = 1`  `end` is at `len`:
            *
            *    iota(4).slide(2) = [[0, 1], [1, 2], [2, 3]    (end = 4)
            *    iota(4).slide(3) = [[0, 1, 2], [1, 2, 3]]     (end = 4)
            *
            * - For the non-trivial cases, we need to calculate the gap
            *   between `len` and `end` - this is the number of missing elements
            *   from the input range:
            *
            *    iota(7).slide(2, 3) = [[0, 1], [3, 4]] || <gap: 2> 6
            *    iota(7).slide(2, 4) = [[0, 1], [4, 5]] || <gap: 1> 6
            *    iota(7).slide(1, 5) = [[0], [5]]       || <gap: 1> 6
            *
            *   As it can be seen `gap` can be at most `stepSize - 1`
            *   More generally the elements of the sliding window with
            *   `w = windowSize` and `s = stepSize` are:
            *
            *     [0, w], [s, s + w], [2 * s, 2 * s + w], ... [n * s, n * s + w]
            *
            *  We can thus calculate the gap between the `end` and `len` as:
            *
            *     gap = len - (n * s + w) = len - w - (n * s)
            *
            *  As we aren't interested in exact value of `n`, but the best
            *  minimal `gap` value, we can use modulo to "cut" `len - w` optimally:
            *
            *     gap = len - w - (s - s ... - s) = (len - w) % s
            *
            *  So for example:
            *
            *    iota(7).slide(2, 3) = [[0, 1], [3, 4]]
            *      gap: (7 - 2) % 3 = 5 % 3 = 2
            *      end: 7 - 2 = 5
            *
            *    iota(7).slide(4, 2) = [[0, 1, 2, 3], [2, 3, 4, 5]]
            *      gap: (7 - 4) % 2 = 3 % 2 = 1
            *      end: 7 - 1 = 6
            */
            pragma(inline, true);
            return (source.length - windowSize)  % stepSize;
        }

        private size_t numberOfFullFrames()
        {
            pragma(inline, true);
            /**
            5.iota.slides(2, 1) => [0, 1], [1, 2], [2, 3], [3, 4]       (4)
            7.iota.slides(2, 2) => [0, 1], [2, 3], [4, 5]               (3)
            7.iota.slides(2, 3) => [0, 1], [3, 4]                       (2)
            7.iota.slides(3, 2) => [0, 1, 2], [2, 3, 4], [4, 5, 6]      (3)
            7.iota.slides(3, 3) => [0, 1, 2], [3, 4, 5]                 (2)

            As the last window is only added iff its complete,
            we don't count the last window.
            */
            return 1 + (source.length - windowSize) / stepSize;
        }

        // Whether the last slide frame size is less than windowSize
        static if (withPartial)
        private bool hasPartialElements()
        {
            pragma(inline, true);
            return gap != 0 && source.length > numberOfFullFrames * stepSize;
        }

        /// Length. Only if `hasLength!Source` is `true`
        @property size_t length()
        {
            if (source.length < windowSize)
            {
                static if (withPartial)
                    return source.length > 0;
                else
                    return 0;
            }
            else
            {
                /***
                  We bump the pointer by stepSize for every element.
                  If withPartial, we don't count the last element if its size
                  isn't windowSize

                  At most:
                      [p, p + stepSize, ..., p + stepSize * n]

                */
                static if (withPartial)
                    /**
                    5.iota.slides(2, 1) => [0, 1], [1, 2], [2, 3], [3, 4]       (4)
                    7.iota.slides(2, 2) => [0, 1], [2, 3], [4, 5], [6]          (4)
                    7.iota.slides(2, 3) => [0, 1], [3, 4], [6]                  (3)
                    7.iota.slides(3, 2) => [0, 1, 2], [2, 3, 4], [4, 5, 6]      (3)
                    7.iota.slides(3, 3) => [0, 1, 2], [3, 4, 5], [6]            (3)
                    */
                    return numberOfFullFrames + hasPartialElements;
                else
                    return numberOfFullFrames;
            }
        }
    }

    static if (hasSlicing!Source)
    {
        /**
        Indexing and slicing operations. Provided only if
        `hasSlicing!Source` is `true`.
         */
        auto opIndex(size_t index)
        {
            immutable start = index * stepSize;

            static if (isInfinite!Source)
            {
                immutable end = start + windowSize;
            }
            else
            {
                import std.algorithm.comparison : min;

                immutable len = source.length;
                assert(start < len, "slide index out of bounds");
                immutable end = min(start + windowSize, len);
            }

            return source[start .. end];
        }

        static if (!isInfinite!Source)
        {
            /// ditto
            typeof(this) opSlice(size_t lower, size_t upper)
            {
                import std.algorithm.comparison : min;
                assert(lower <= upper && upper <= length, "slide slicing index out of bounds");

                lower *= stepSize;
                upper *= stepSize;

                immutable len = source.length;

                /*
                After we have normalized `lower` and `upper` by `stepSize`,
                we only need to look at the case of `stepSize=1`.
                As `leftPos`, is equal to `lower`, we will only look `rightPos`.
                Notice that starting from `upper`,
                we only need to move for `windowSize - 1` to the right:

                  - [0, 1, 2, 3].slide(2) -> s = [[0, 1], [1, 2], [2, 3]]
                    rightPos for s[0..3]: (upper=3) + (windowSize=2) - 1 = 4

                  - [0, 1, 2, 3].slide(3) -> s = [[0, 1, 2], [1, 2, 3]]
                    rightPos for s[0..2]: (upper=2) + (windowSize=3) - 1 = 4

                  - [0, 1, 2, 3, 4].slide(4) -> s = [[0, 1, 2, 3], [1, 2, 3, 4]]
                    rightPos for s[0..2]: (upper=2) + (windowSize=4) - 1 = 5
                */
                return typeof(this)
                    (source[min(lower, len) .. min(upper + windowSize - 1, len)],
                     windowSize, stepSize);
            }
        }
        else static if (hasSliceToEnd)
        {
            // For slicing an infinite chunk, we need to slice the source to the infinite end.
            auto opSlice(size_t lower, size_t upper)
            {
                assert(lower <= upper, "slide slicing index out of bounds");
                return typeof(this)(source[lower * stepSize .. $],
                       windowSize, stepSize).takeExactly(upper - lower);
            }
        }

        static if (isInfinite!Source)
        {
            static if (hasSliceToEnd)
            {
                private static struct DollarToken{}
                DollarToken opDollar()
                {
                    return DollarToken();
                }
                //Slice to dollar
                typeof(this) opSlice(size_t lower, DollarToken)
                {
                    return typeof(this)(source[lower * stepSize .. $], windowSize, stepSize);
                }
            }
        }
        else
        {
            // Dollar token carries a static type, with no extra information.
            // It can lazily transform into source.length on algorithmic
            // operations such as : slide[$/2, $-1];
            private static struct DollarToken
            {
                private size_t _length;
                alias _length this;
            }

            DollarToken opDollar()
            {
                return DollarToken(this.length);
            }

            // Optimized slice overloads optimized for using dollar.
            typeof(this) opSlice(DollarToken, DollarToken)
            {
                static if (hasSliceToEnd)
                {
                    return typeof(this)(source[$ .. $], windowSize, stepSize);
                }
                else
                {
                    immutable len = source.length;
                    return typeof(this)(source[len .. len], windowSize, stepSize);
                }
            }

            // Optimized slice overloads optimized for using dollar.
            typeof(this) opSlice(size_t lower, DollarToken)
            {
                import std.algorithm.comparison : min;
                assert(lower <= length, "slide slicing index out of bounds");
                lower *= stepSize;
                static if (hasSliceToEnd)
                {
                    return typeof(this)(source[min(lower, source.length) .. $], windowSize, stepSize);
                }
                else
                {
                    immutable len = source.length;
                    return typeof(this)(source[min(lower, len) .. len], windowSize, stepSize);
                }
            }

            // Optimized slice overloads optimized for using dollar.
            typeof(this) opSlice(DollarToken, size_t upper)
            {
                assert(upper == length, "slide slicing index out of bounds");
                return this[$ .. $];
            }
        }

        // Bidirectional range primitives
        static if (!isInfinite!Source)
        {
            /**
            Bidirectional range primitives. Provided only if both
            `hasSlicing!Source` and `!isInfinite!Source` are `true`.
             */
            @property auto back()
            {
                import std.algorithm.comparison : max;

                assert(!empty, "Attempting to access front on an empty slide");

                immutable len = source.length;

                static if (withPartial)
                {
                    if (source.length <= windowSize)
                        return source[0 .. source.length];

                    if (hasPartialElements)
                        return source[numberOfFullFrames * stepSize .. len];
                }

                // check for underflow
                immutable start = (len > windowSize + gap) ? len - windowSize - gap : 0;
                return source[start .. len - gap];
            }

            /// Ditto
            void popBack()
            {
                assert(!empty, "Attempting to call popBack() on an empty slide");

                // Move by stepSize
                immutable end = source.length > stepSize ? source.length - stepSize : 0;

                static if (withPartial)
                {
                    if (hasShownPartialBefore || source.empty)
                    {
                        _empty = true;
                        return;
                    }

                    // pop by stepSize, except for the partial frame at the end
                    if (hasPartialElements)
                        source = source[0 .. source.length - gap];
                    else
                        source = source[0 .. end];
                }
                else
                {
                    source = source[0 .. end];
                }

                if (source.length < windowSize)
                    _empty = true;
            }
        }
    }
}

///
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    assert([0, 1, 2, 3].slide(2).equal!equal(
        [[0, 1], [1, 2], [2, 3]]
    ));

    assert(5.iota.slide(3).equal!equal(
        [[0, 1, 2], [1, 2, 3], [2, 3, 4]]
    ));

    assert(iota(7).slide(2, 2).equal!equal(
        [[0, 1], [2, 3], [4, 5], [6]]
    ));

    assert(iota(12).slide(2, 4).equal!equal(
        [[0, 1], [4, 5], [8, 9]]
    ));
}

/// set a custom stepsize (default 1)
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    assert(6.iota.slide(1, 2).equal!equal(
        [[0], [2], [4]]
    ));

    assert(6.iota.slide(2, 4).equal!equal(
        [[0, 1], [4, 5]]
    ));
}

/// allow slide with less elements than the window size
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    assert(3.iota.slide!(No.withPartial)(4).empty);
    assert(3.iota.slide!(Yes.withPartial)(4).equal!equal(
        [[0, 1, 2]]
    ));
}

/// count k-mers
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;
    import std.algorithm.iteration : each;

    int[dstring] d;
    "AGAGA"d.slide!(Yes.withPartial)(2).each!(a => d[a]++);
    assert(d == ["AG"d: 2, "GA"d: 2]);
}

// test @nogc
@safe pure nothrow @nogc unittest
{
    import std.algorithm.comparison : equal;

    static immutable res1 = [[0], [1], [2], [3]];
    assert(4.iota.slide!(Yes.withPartial)(1).equal!equal(res1));

    static immutable res2 = [[0, 1], [1, 2], [2, 3]];
    assert(4.iota.slide!(Yes.withPartial)(2).equal!equal(res2));
}

// different window sizes
@safe pure nothrow unittest
{
    import std.array : array;
    import std.algorithm.comparison : equal;

    assert([0, 1, 2, 3].slide!(Yes.withPartial)(1).array == [[0], [1], [2], [3]]);
    assert([0, 1, 2, 3].slide!(Yes.withPartial)(2).array == [[0, 1], [1, 2], [2, 3]]);
    assert([0, 1, 2, 3].slide!(Yes.withPartial)(3).array == [[0, 1, 2], [1, 2, 3]]);
    assert([0, 1, 2, 3].slide!(Yes.withPartial)(4).array == [[0, 1, 2, 3]]);
    assert([0, 1, 2, 3].slide!(No.withPartial)(5).walkLength == 0);
    assert([0, 1, 2, 3].slide!(Yes.withPartial)(5).array == [[0, 1, 2, 3]]);


    assert(iota(2).slide!(Yes.withPartial)(2).front.equal([0, 1]));
    assert(iota(3).slide!(Yes.withPartial)(2).equal!equal([[0, 1],[1, 2]]));
    assert(iota(3).slide!(Yes.withPartial)(3).equal!equal([[0, 1, 2]]));
    assert(iota(3).slide!(No.withPartial)(4).walkLength == 0);
    assert(iota(3).slide!(Yes.withPartial)(4).equal!equal([[0, 1, 2]]));
    assert(iota(1, 4).slide!(Yes.withPartial)(1).equal!equal([[1], [2], [3]]));
    assert(iota(1, 4).slide!(Yes.withPartial)(3).equal!equal([[1, 2, 3]]));
}

// test combinations
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    assert(6.iota.slide!(Yes.withPartial)(1, 1).equal!equal(
        [[0], [1], [2], [3], [4], [5]]
    ));
    assert(6.iota.slide!(Yes.withPartial)(1, 2).equal!equal(
        [[0], [2], [4]]
    ));
    assert(6.iota.slide!(Yes.withPartial)(1, 3).equal!equal(
        [[0], [3]]
    ));
    assert(6.iota.slide!(Yes.withPartial)(1, 4).equal!equal(
        [[0], [4]]
    ));
    assert(6.iota.slide!(Yes.withPartial)(1, 5).equal!equal(
        [[0], [5]]
    ));
    assert(6.iota.slide!(Yes.withPartial)(2, 1).equal!equal(
        [[0, 1], [1, 2], [2, 3], [3, 4], [4, 5]]
    ));
    assert(6.iota.slide!(Yes.withPartial)(2, 2).equal!equal(
        [[0, 1], [2, 3], [4, 5]]
    ));
    assert(6.iota.slide!(Yes.withPartial)(2, 3).equal!equal(
        [[0, 1], [3, 4]]
    ));
    assert(6.iota.slide!(Yes.withPartial)(2, 4).equal!equal(
        [[0, 1], [4, 5]]
    ));

    // partial elements
    assert(6.iota.slide!(Yes.withPartial)(2, 5).equal!equal(
        [[0, 1], [5]]
    ));
    assert(6.iota.slide!(No.withPartial)(2, 5).equal!equal(
        [[0, 1]]
    ));

    assert(6.iota.slide!(Yes.withPartial)(3, 1).equal!equal(
        [[0, 1, 2], [1, 2, 3], [2, 3, 4], [3, 4, 5]]
    ));

    // partial elements
    assert(6.iota.slide!(Yes.withPartial)(3, 2).equal!equal(
        [[0, 1, 2], [2, 3, 4], [4, 5]]
    ));
    assert(6.iota.slide!(No.withPartial)(3, 2).equal!equal(
        [[0, 1, 2], [2, 3, 4]]
    ));

    assert(6.iota.slide!(Yes.withPartial)(3, 3).equal!equal(
        [[0, 1, 2], [3, 4, 5]]
    ));

    // partial elements
    assert(6.iota.slide!(Yes.withPartial)(3, 4).equal!equal(
        [[0, 1, 2], [4, 5]]
    ));
    assert(6.iota.slide!(No.withPartial)(3, 4).equal!equal(
        [[0, 1, 2]]
    ));

    assert(6.iota.slide!(Yes.withPartial)(4, 1).equal!equal(
        [[0, 1, 2, 3], [1, 2, 3, 4], [2, 3, 4, 5]]
    ));
    assert(6.iota.slide!(Yes.withPartial)(4, 2).equal!equal(
        [[0, 1, 2, 3], [2, 3, 4, 5]]
    ));

    // partial elements
    assert(6.iota.slide!(Yes.withPartial)(4, 3).equal!equal(
        [[0, 1, 2, 3], [3, 4, 5]]
    ));
    assert(6.iota.slide!(No.withPartial)(4, 3).equal!equal(
        [[0, 1, 2, 3]]
    ));

    assert(6.iota.slide!(Yes.withPartial)(5, 1).equal!equal(
        [[0, 1, 2, 3, 4], [1, 2, 3, 4, 5]]
    ));

    // partial elements
    assert(6.iota.slide!(Yes.withPartial)(5, 2).equal!equal(
        [[0, 1, 2, 3, 4], [2, 3, 4, 5]]
    ));
    assert(6.iota.slide!(No.withPartial)(5, 2).equal!equal(
        [[0, 1, 2, 3, 4]]
    ));

    assert(6.iota.slide!(Yes.withPartial)(5, 3).equal!equal(
        [[0, 1, 2, 3, 4], [3, 4, 5]]
    ));
    assert(6.iota.slide!(No.withPartial)(5, 3).equal!equal(
        [[0, 1, 2, 3, 4]]
    ));
}

// test emptyness, copyability and strings
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;
    import std.algorithm.iteration : each, map;

    // check with empty input
    int[] d;
    assert(d.slide!(Yes.withPartial)(2).empty);
    assert(d.slide!(Yes.withPartial)(2, 2).empty);

    // is copyable?
    auto e = iota(5).slide!(Yes.withPartial)(2);
    e.popFront;
    assert(e.save.equal!equal([[1, 2], [2, 3], [3, 4]]));
    assert(e.save.equal!equal([[1, 2], [2, 3], [3, 4]]));
    assert(e.map!"a.array".array == [[1, 2], [2, 3], [3, 4]]);

    // test with strings
    int[dstring] f;
    "AGAGA"d.slide!(Yes.withPartial)(3).each!(a => f[a]++);
    assert(f == ["AGA"d: 2, "GAG"d: 1]);

    int[dstring] g;
    "ABCDEFG"d.slide!(Yes.withPartial)(3, 3).each!(a => g[a]++);
    assert(g == ["ABC"d:1, "DEF"d:1, "G": 1]);
    g = null;
    "ABCDEFG"d.slide!(No.withPartial)(3, 3).each!(a => g[a]++);
    assert(g == ["ABC"d:1, "DEF"d:1]);
}

// test length
@safe pure nothrow unittest
{
    // Slides with fewer elements are empty or 1 for Yes.withPartial
    static foreach (expectedLength, Partial; [No.withPartial, Yes.withPartial])
    {{
        assert(iota(3).slide!(Partial)(4, 2).walkLength == expectedLength);
        assert(iota(3).slide!(Partial)(4).walkLength == expectedLength);
        assert(iota(3).slide!(Partial)(4, 3).walkLength == expectedLength);
    }}
}

// test length
@safe pure nothrow unittest
{
    // [0, 1], [1, 2], [2, 3], [3, 4]
    assert(5.iota.slide!(Yes.withPartial)(2, 1).length == 4);
    // [0, 1], [2, 3], [4, 5], [6]
    assert(7.iota.slide!(Yes.withPartial)(2, 2).length == 4);
    // [0, 1], [3, 4], [6]
    assert(7.iota.slide!(Yes.withPartial)(2, 3).length == 3);
    // [0, 1, 2], [2, 3, 4], [4, 5, 6]
    assert(7.iota.slide!(Yes.withPartial)(3, 2).length == 3);
    // [0, 1, 2], [3, 4, 5], [6]
    assert(7.iota.slide!(Yes.withPartial)(3, 3).length == 3);
}

// test length (Yes.withPartial)
@safe pure nothrow unittest
{
    assert(4.iota.slide!(Yes.withPartial)(2).length == 3);
    assert(5.iota.slide!(Yes.withPartial)(3).length == 3);
    assert(7.iota.slide!(Yes.withPartial)(2, 2).length == 4);
    assert(12.iota.slide!(Yes.withPartial)(2, 4).length == 3);
    assert(6.iota.slide!(Yes.withPartial)(1, 2).length == 3);
    assert(6.iota.slide!(Yes.withPartial)(2, 4).length == 2);
    assert(3.iota.slide!(Yes.withPartial)(4).length == 1);
}

// test length (No.withPartial)
@safe pure nothrow unittest
{
    // [0, 1], [1, 2], [2, 3], [3, 4]
    assert(5.iota.slide!(No.withPartial)(2, 1).length == 4);
    // [0, 1], [2, 3], [4, 5]
    assert(7.iota.slide!(No.withPartial)(2, 2).length == 3);
    // [0, 1], [3, 4]
    assert(7.iota.slide!(No.withPartial)(2, 3).length == 2);
    // [0, 1, 2], [2, 3, 4], [4, 5, 6]
    assert(7.iota.slide!(No.withPartial)(3, 2).length == 3);
    // [0, 1, 2], [3, 4, 5]
    assert(7.iota.slide!(No.withPartial)(3, 3).length == 2);
}

// test index
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    static foreach (Partial; [Yes.withPartial, No.withPartial])
    {
        assert(iota(3).slide!Partial(4)[0].equal([0, 1, 2]));
        assert(iota(5).slide!Partial(4)[1].equal([1, 2, 3, 4]));
        assert(iota(3).slide!Partial(4, 2)[0].equal([0, 1, 2]));
        assert(iota(5).slide!Partial(4, 2)[1].equal([2, 3, 4]));
        assert(iota(3).slide!Partial(4, 3)[0].equal([0, 1, 2]));
        assert(iota(3).slide!Partial(4, 3)[0].equal([0, 1, 2]));
        assert(iota(5).slide!Partial(4, 3)[1].equal([3, 4,]));
    }
}

// test slicing
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    static foreach (Partial; [Yes.withPartial, No.withPartial])
    {
        assert(iota(3).slide!Partial(2)[1 .. $].equal!equal([[1, 2]]));
        assert(iota(1, 5).slide!Partial(2)[0 .. 1].equal!equal([[1, 2]]));
        assert(iota(1, 5).slide!Partial(2)[0 .. 2].equal!equal([[1, 2], [2, 3]]));
        assert(iota(1, 5).slide!Partial(2)[1 .. 2].equal!equal([[2, 3]]));
        assert(iota(1, 5).slide!Partial(3)[0 .. 1].equal!equal([[1, 2, 3]]));
        assert(iota(1, 5).slide!Partial(3)[0 .. 2].equal!equal([[1, 2, 3], [2, 3, 4]]));
        assert(iota(1, 6).slide!Partial(3)[2 .. 3].equal!equal([[3, 4, 5]]));
        assert(iota(1, 5).slide!Partial(4)[0 .. 1].equal!equal([[1, 2, 3, 4]]));
    }

    // special cases
    assert(iota(3).slide!(Yes.withPartial)(4)[0 .. $].equal!equal([[0, 1, 2]]));
    assert(iota(3).slide!(No.withPartial)(4)[0 .. $].empty);
}

// length
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    static foreach (Partial; [Yes.withPartial, No.withPartial])
    {
        assert(iota(3).slide!Partial(1).length == 3);
        assert(iota(3).slide!Partial(1, 2).length == 2);
        assert(iota(3).slide!Partial(1, 3).length == 1);
        assert(iota(3).slide!Partial(1, 4).length == 1);
        assert(iota(3).slide!Partial(2).length == 2);
        assert(iota(3).slide!Partial(2, 3).length == 1);
        assert(iota(3).slide!Partial(3).length == 1);
        assert(iota(3).slide!Partial(3, 2).length == 1);
    }

    // length special cases
    assert(iota(3).slide!(Yes.withPartial)(2, 2).length == 2);
    assert(iota(3).slide!(No.withPartial)(2, 2).length == 1);
}

// opDollar
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    static foreach (Partial; [Yes.withPartial, No.withPartial])
    {
        assert(iota(4).slide!Partial(4)[$/2 .. $].equal!equal([[0, 1, 2, 3]]));
        assert(iota(5).slide!Partial(4)[$ .. $].empty);
        assert(iota(5).slide!Partial(4)[$ .. 2].empty);
        assert(iota(5).slide!Partial(4)[$ .. 2].empty);
    }
}

// slicing
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    static foreach (Partial; [Yes.withPartial, No.withPartial])
    {
        assert(iota(5).slide!Partial(3, 1)[$/2 .. $].equal!equal([[1, 2, 3], [2, 3, 4]]));
        assert(iota(5).slide!Partial(3, 2)[$/2 .. $].equal!equal([[2, 3, 4]]));
        assert(iota(3).slide!Partial(4, 3)[$ .. $].empty);
    }
    assert(iota(5).slide!(Yes.withPartial)(3, 3)[$/2 .. $].equal!equal([[3, 4]]));
    assert(iota(5).slide!(No.withPartial)(3, 3)[$/2 .. $].equal!equal([[0, 1, 2]]));
    assert(iota(3).slide!(Yes.withPartial)(4, 3)[$ .. 1].empty);
}

// test opDollar slicing with No.withPartial
@safe pure nothrow unittest
{
    assert(iota(3).slide!(Yes.withPartial)(4).length == 1);
    assert(iota(3).slide!(Yes.withPartial)(4, 4).length == 1);

    assert(iota(3).slide!(No.withPartial)(4).empty);
    assert(iota(3, 3).slide!(No.withPartial)(4).empty);
    assert(iota(3).slide!(No.withPartial)(4).length == 0);
    assert(iota(3).slide!(No.withPartial)(4, 4).length == 0);

    assert(iota(3).slide!(No.withPartial)(400).empty);
    assert(iota(3).slide!(No.withPartial)(400).length == 0);
    assert(iota(3).slide!(No.withPartial)(400, 10).length == 0);

    assert(iota(3).slide!(No.withPartial)(4)[0 .. $].empty);
    assert(iota(3).slide!(No.withPartial)(4)[$ .. $].empty);
    assert(iota(3).slide!(No.withPartial)(4)[$ .. 0].empty);
    assert(iota(3).slide!(No.withPartial)(4)[$/2 .. $].empty);

    // with different step sizes
    assert(iota(3).slide!(No.withPartial)(4, 5)[0 .. $].empty);
    assert(iota(3).slide!(No.withPartial)(4, 6)[$ .. $].empty);
    assert(iota(3).slide!(No.withPartial)(4, 7)[$ .. 0].empty);
    assert(iota(3).slide!(No.withPartial)(4, 8)[$/2 .. $].empty);
}

// test opDollar slicing with Yes.withPartial
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    assert(iota(3).slide!(Yes.withPartial)(4)[0 .. $].equal!equal([[0, 1, 2]]));
    assert(iota(3).slide!(Yes.withPartial)(4)[$ .. $].empty);
    //assert(iota(3).slide!(Yes.withPartial)(4)[$ .. 0].empty);
    assert(iota(3).slide!(Yes.withPartial)(4)[$/2 .. $].equal!equal([[0, 1, 2]]));

    // with different step sizes
    assert(iota(3).slide!(Yes.withPartial)(4, 5)[0 .. $].equal!equal([[0, 1, 2]]));
    assert(iota(3).slide!(Yes.withPartial)(4, 6)[$ .. $].empty);
    //assert(iota(3).slide!(Yes.withPartial)(4, 7)[$ .. 0].empty);
    assert(iota(3).slide!(Yes.withPartial)(4, 8)[$/2 .. $].equal!equal([[0, 1, 2]]));

    // with different step sizes
    // TODO:
    //iota(10).slide!(Yes.withPartial)(4, 3)[0 .. $/2].writeln;
    //iota(10).slide!(Yes.withPartial)(4, 3)[$/2 .. $].writeln;
    //assert(iota(10).slide!(Yes.withPartial)(4, 3)[$/2 .. $].equal!equal([[6, 7, 8, 9]]));
    //assert(iota(10).slide!(Yes.withPartial)(4, 4)[$/2 .. $].equal!equal([[4, 5, 6, 7]]));
}

// test with infinite ranges
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    static foreach (Partial; [Yes.withPartial, No.withPartial])
    {{
        // InfiniteRange without RandomAccess
        auto fibs = recurrence!"a[n-1] + a[n-2]"(1, 1);
        assert(fibs.slide!Partial(2).take(2).equal!equal([[1,  1], [1,  2]]));
        assert(fibs.slide!Partial(2, 3).take(2).equal!equal([[1,  1], [3,  5]]));

        // InfiniteRange with RandomAccess and slicing
        auto odds = sequence!("a[0] + n * a[1]")(1, 2);
        auto oddsByPairs = odds.slide!Partial(2);
        assert(oddsByPairs.take(2).equal!equal([[ 1,  3], [ 3,  5]]));
        assert(oddsByPairs[1].equal([3, 5]));
        assert(oddsByPairs[4].equal([9, 11]));

        static assert(hasSlicing!(typeof(odds)));
        assert(oddsByPairs[3 .. 5].equal!equal([[7, 9], [9, 11]]));
        assert(oddsByPairs[3 .. $].take(2).equal!equal([[7, 9], [9, 11]]));

        auto oddsWithGaps = odds.slide!Partial(2, 4);
        assert(oddsWithGaps.take(3).equal!equal([[1, 3], [9, 11], [17, 19]]));
        assert(oddsWithGaps[2].equal([17, 19]));
        assert(oddsWithGaps[1 .. 3].equal!equal([[9, 11], [17, 19]]));
        assert(oddsWithGaps[1 .. $].take(2).equal!equal([[9, 11], [17, 19]]));
    }}
}

// test reverse
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    static foreach (Partial; [Yes.withPartial, No.withPartial])
    {{
        auto e1 = iota(3).slide!Partial(2);
        assert(e1.retro.equal!equal([[1, 2], [0, 1]]));
        assert(e1.retro.array.equal(e1.array.retro));

        auto e2 = iota(5).slide!Partial(3);
        assert(e2.retro.equal!equal([[2, 3, 4], [1, 2, 3], [0, 1, 2]]));
        assert(e2.retro.array.equal(e2.array.retro));

        auto e3 = iota(3).slide!Partial(4);
        static if (Partial == Yes.withPartial)
            assert(e3.retro.walkLength == 1);
        else
            assert(e3.retro.walkLength == 0);
        assert(e3.retro.array.equal(e3.array.retro));
    }}
}

// test reverse with different steps
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    // TODO
    static foreach (Partial; [Yes.withPartial, No.withPartial])
    {{
        assert(iota(7).slide!Partial(2, 1).retro.equal!equal(
            [[5, 6], [4, 5], [3, 4], [2, 3], [1, 2], [0, 1]]
        ));
        assert(iota(7).slide!Partial(2, 4).retro.equal!equal(
            [[4, 5], [0, 1]]
        ));
        assert(iota(7).slide!Partial(2, 5).retro.equal!equal(
            [[5, 6], [0, 1]]
        ));
        assert(iota(7).slide!Partial(3, 1).retro.equal!equal(
            [[4, 5, 6], [3, 4, 5], [2, 3, 4], [1, 2, 3], [0, 1, 2]]
        ));
        assert(iota(7).slide!Partial(3, 2).retro.equal!equal(
            [[4, 5, 6], [2, 3, 4], [0, 1, 2]]
        ));
        assert(iota(7).slide!Partial(4, 1).retro.equal!equal(
            [[3, 4, 5, 6], [2, 3, 4, 5], [1, 2, 3, 4], [0, 1, 2, 3]]
        ));
        assert(iota(7).slide!Partial(4, 3).retro.equal!equal(
            [[3, 4, 5, 6], [0, 1, 2, 3]]
        ));
        assert(iota(7).slide!Partial(5, 1).retro.equal!equal(
            [[2, 3, 4, 5, 6], [1, 2, 3, 4, 5], [0, 1, 2, 3, 4]]
        ));
        assert(iota(7).slide!Partial(5, 2).retro.equal!equal(
            [[2, 3, 4, 5, 6], [0, 1, 2, 3, 4]]
        ));
    }}
}

// test reverse (special cases for No.withPartial)
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    assert(iota(7).slide!(No.withPartial)(2, 2).retro.equal!equal(
        [[4, 5], [2, 3], [0, 1]]
    ));
    assert(iota(7).slide!(No.withPartial)(2, 3).retro.equal!equal(
        [[3, 4], [0, 1]]
    ));
    assert(iota(7).slide!(No.withPartial)(4, 2).retro.equal!equal(
        [[2, 3, 4, 5], [0, 1, 2, 3]]
    ));
    assert(iota(7).slide!(No.withPartial)(4, 4).retro.equal!equal(
        [[0, 1, 2, 3]]
    ));
    assert(iota(7).slide!(No.withPartial)(5, 3).retro.equal!equal(
        [[0, 1, 2, 3, 4]]
    ));
    assert(iota(7).slide!(No.withPartial)(5, 4).retro.equal!equal(
        [[0, 1, 2, 3, 4]]
    ));
}

// test reverse (special cases for Yes.withPartial)
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    assert(iota(7).slide!(Yes.withPartial)(2, 2).retro.equal!equal(
        [[6], [4, 5], [2, 3], [0, 1]]
    ));
    assert(iota(7).slide!(Yes.withPartial)(2, 3).retro.equal!equal(
        [[6], [3, 4], [0, 1]]
    ));
    assert(iota(7).slide!(Yes.withPartial)(4, 2).retro.equal!equal(
        [[4, 5, 6], [2, 3, 4, 5], [0, 1, 2, 3]]
    ));
    assert(iota(7).slide!(Yes.withPartial)(4, 4).retro.equal!equal(
        [[4, 5, 6], [0, 1, 2, 3]]
    ));
    assert(iota(7).slide!(Yes.withPartial)(5, 3).retro.equal!equal(
        [[3, 4, 5, 6], [0, 1, 2, 3, 4]]
    ));
    assert(iota(7).slide!(Yes.withPartial)(5, 4).retro.equal!equal(
        [[4, 5, 6], [0, 1, 2, 3, 4]]
    ));
}

// test different step sizes
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    assert(iota(7).slide!(No.withPartial)(2, 2).equal!equal([[0, 1], [2, 3], [4, 5]]));
    assert(iota(8).slide!(No.withPartial)(2, 2).equal!equal([[0, 1], [2, 3], [4, 5], [6, 7]]));
    assert(iota(9).slide!(No.withPartial)(2, 2).equal!equal([[0, 1], [2, 3], [4, 5], [6, 7]]));
    assert(iota(12).slide!(No.withPartial)(2, 4).equal!equal([[0, 1], [4, 5], [8, 9]]));
    assert(iota(13).slide!(No.withPartial)(2, 4).equal!equal([[0, 1], [4, 5], [8, 9]]));

    assert(iota(7).slide!(Yes.withPartial)(2, 2).equal!equal([[0, 1], [2, 3], [4, 5], [6]]));
    assert(iota(8).slide!(Yes.withPartial)(2, 2).equal!equal([[0, 1], [2, 3], [4, 5], [6, 7]]));
    assert(iota(9).slide!(Yes.withPartial)(2, 2).equal!equal([[0, 1], [2, 3], [4, 5], [6, 7], [8]]));
    assert(iota(12).slide!(Yes.withPartial)(2, 4).equal!equal([[0, 1], [4, 5], [8, 9]]));
    assert(iota(13).slide!(Yes.withPartial)(2, 4).equal!equal([[0, 1], [4, 5], [8, 9], [12]]));
}

// test with dummy ranges
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;
    import std.internal.test.dummyrange : AllDummyRanges;
    import std.meta : Filter;

    static foreach (Range; Filter!(isForwardRange, AllDummyRanges))
    {{
        Range r;

        static foreach (Partial; [Yes.withPartial, No.withPartial])
        {
            assert(r.slide!Partial(1).equal!equal(
                [[1], [2], [3], [4], [5], [6], [7], [8], [9], [10]]
            ));
            assert(r.slide!Partial(2).equal!equal(
                [[1, 2], [2, 3], [3, 4], [4, 5], [5, 6], [6, 7], [7, 8], [8, 9], [9, 10]]
            ));
            assert(r.slide!Partial(3).equal!equal(
                [[1, 2, 3], [2, 3, 4], [3, 4, 5], [4, 5, 6],
                [5, 6, 7], [6, 7, 8], [7, 8, 9], [8, 9, 10]]
            ));
            assert(r.slide!Partial(6).equal!equal(
                [[1, 2, 3, 4, 5, 6], [2, 3, 4, 5, 6, 7], [3, 4, 5, 6, 7, 8],
                [4, 5, 6, 7, 8, 9], [5, 6, 7, 8, 9, 10]]
            ));
        }

        // special cases
        assert(r.slide!(Yes.withPartial)(15).equal!equal(
            [[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]]
        ));
        assert(r.slide!(Yes.withPartial)(15).walkLength == 1);

        assert(r.slide!(No.withPartial)(15).empty);
        assert(r.slide!(No.withPartial)(15).walkLength == 0);
    }}
}

// test with dummy ranges
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;
    import std.internal.test.dummyrange : AllDummyRanges;
    import std.meta : Filter;

    static foreach (Range; Filter!(isForwardRange, AllDummyRanges))
    {{
        Range r;

        static foreach (Partial; [Yes.withPartial, No.withPartial])
        {
            assert(r.take(6).slide!(Yes.withPartial)(4, 6).equal!equal(
                [[1, 2, 3, 4]]
            ));
            assert(r.take(6).slide!(Yes.withPartial)(4, 3).equal!equal(
                [[1, 2, 3, 4], [4, 5, 6]]
            ));
            assert(r.take(6).slide!(Yes.withPartial)(4, 2).equal!equal(
                [[1, 2, 3, 4], [3, 4, 5, 6]]
            ));
            assert(r.take(6).slide!(Yes.withPartial)(4, 1).equal!equal(
                [[1, 2, 3, 4], [2, 3, 4, 5], [3, 4, 5, 6]]
            ));

            assert(r.take(7).slide!(Yes.withPartial)(4, 3).equal!equal(
                [[1, 2, 3, 4], [4, 5, 6, 7]]
            ));
            assert(r.take(7).slide!(Yes.withPartial)(4, 1).equal!equal(
                [[1, 2, 3, 4], [2, 3, 4, 5], [3, 4, 5, 6], [4, 5, 6, 7]]
            ));

            assert(r.take(8).slide!(Yes.withPartial)(4, 2).equal!equal(
                [[1, 2, 3, 4], [3, 4, 5, 6], [5, 6, 7, 8]]
            ));
            assert(r.take(8).slide!(Yes.withPartial)(4, 1).equal!equal(
                [[1, 2, 3, 4], [2, 3, 4, 5], [3, 4, 5, 6], [4, 5, 6, 7], [5, 6, 7, 8]]
            ));
            assert(r.take(8).slide!(Yes.withPartial)(3, 3).equal!equal(
                [[1, 2, 3], [4, 5, 6], [7, 8]]
            ));
            assert(r.take(8).slide!(Yes.withPartial)(3, 4).equal!equal(
                [[1, 2, 3], [5, 6, 7]]
            ));

            assert(r.slide!(Yes.withPartial)(7, 6).equal!equal(
                [[1, 2, 3, 4, 5, 6, 7], [7, 8, 9, 10]]
            ));
            assert(r.slide!(Yes.withPartial)(3, 7).equal!equal(
                [[1, 2, 3], [8, 9, 10]]
            ));
        }

        // test special cases
        assert(r.take(7).slide!(Yes.withPartial)(4, 5).equal!equal(
            [[1, 2, 3, 4], [6, 7]]
        ));
        assert(r.take(7).slide!(No.withPartial)(4, 5).equal!equal(
            [[1, 2, 3, 4]]
        ));

        assert(r.take(7).slide!(Yes.withPartial)(4, 4).equal!equal(
            [[1, 2, 3, 4], [5, 6, 7]]
        ));
        assert(r.take(7).slide!(No.withPartial)(4, 4).equal!equal(
            [[1, 2, 3, 4]]
        ));

        assert(r.take(7).slide!(Yes.withPartial)(4, 2).equal!equal(
            [[1, 2, 3, 4], [3, 4, 5, 6], [5, 6, 7]]
        ));
        assert(r.take(7).slide!(No.withPartial)(4, 2).equal!equal(
            [[1, 2, 3, 4], [3, 4, 5, 6]]
        ));

        assert(r.take(8).slide!(Yes.withPartial)(4, 3).equal!equal(
            [[1, 2, 3, 4], [4, 5, 6, 7], [7, 8]]
        ));
        assert(r.take(8).slide!(No.withPartial)(4, 3).equal!equal(
            [[1, 2, 3, 4], [4, 5, 6, 7]]
        ));

        assert(r.take(8).slide!(No.withPartial)(3, 6).equal!equal(
            [[1, 2, 3]]
        ));
        assert(r.take(8).slide!(Yes.withPartial)(3, 6).equal!equal(
            [[1, 2, 3], [7, 8]]
        ));

        assert(r.slide!(Yes.withPartial)(3, 8).equal!equal(
            [[1, 2, 3], [9, 10]]
        ));
        assert(r.slide!(No.withPartial)(3, 8).equal!equal(
            [[1, 2, 3]]
        ));
    }}
}

@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;
    import std.internal.test.dummyrange : AllDummyRanges;
    import std.meta : Filter, templateAnd;

    static foreach (Range; Filter!(templateAnd!(hasSlicing, hasLength, isBidirectionalRange), AllDummyRanges))
    {{
        Range r;
        static foreach (Partial; [Yes.withPartial, No.withPartial])
        {
            assert(r.slide!Partial(1).array.retro.equal!equal(
                [[10], [9], [8], [7], [6], [5], [4], [3], [2], [1]]
            ));
            assert(r.slide!Partial(2).retro.equal!equal(
                [[9, 10], [8, 9], [7, 8], [6, 7], [5, 6], [4, 5], [3, 4], [2, 3], [1, 2]]
            ));
            assert(r.slide!Partial(5).retro.equal!equal(
                [[6, 7, 8, 9, 10], [5, 6, 7, 8, 9], [4, 5, 6, 7, 8],
                [3, 4, 5, 6, 7], [2, 3, 4, 5, 6], [1, 2, 3, 4, 5]]
            ));

            // different step sizes
            assert(r.slide!Partial(2, 4)[2].equal([9, 10]));
            assert(r.slide!Partial(2, 1).equal!equal(
                [[1, 2], [2, 3], [3, 4], [4, 5], [5, 6], [6, 7], [7, 8], [8, 9], [9, 10]]
            ));
            assert(r.slide!Partial(2, 2).equal!equal(
                [[1, 2], [3, 4], [5, 6], [7, 8], [9, 10]]
            ));
            assert(r.slide!Partial(2, 4).equal!equal(
                [[1, 2], [5, 6], [9, 10]]
            ));

            // front = back
            foreach (windowSize; 1 .. 10)
            foreach (stepSize; 1 .. 10)
            {
                auto slider = r.slide!Partial(windowSize, stepSize);
                assert(slider.retro.array.retro.equal!equal(slider));
            }
        }

        // special cases
        assert(r.slide!(No.withPartial)(15).retro.walkLength == 0);
        assert(r.slide!(Yes.withPartial)(15).retro.equal!equal(
            [[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]]
        ));
    }}
}

@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    static foreach (Partial; [Yes.withPartial, No.withPartial])
    {{
        assert(iota(1, 12).slide!Partial(2, 4)[0 .. 3].equal!equal([[1, 2], [5, 6], [9, 10]]));
        assert(iota(1, 12).slide!Partial(2, 4)[0 .. $].equal!equal([[1, 2], [5, 6], [9, 10]]));
        assert(iota(1, 12).slide!Partial(2, 4)[$/2 .. $].equal!equal([[5, 6], [9, 10]]));

        // reverse
        assert(iota(1, 12).slide!Partial(2, 4).retro.equal!equal([[9, 10], [5, 6], [1, 2]]));
    }}
}

// test different sliceable ranges
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;
    import std.internal.test.dummyrange : DummyRange, Length, RangeType, ReturnBy;
    import std.meta : AliasSeq;

    struct SliceableRange(Range, Flag!"withOpDollar" withOpDollar = No.withOpDollar,
                                 Flag!"withInfiniteness" withInfiniteness = No.withInfiniteness)
    {
        Range arr = 10.iota.array; // similar to DummyRange
        @property auto save() { return typeof(this)(arr); }
        @property auto front() { return arr[0]; }
        void popFront() { arr.popFront(); }
        auto opSlice(size_t i, size_t j)
        {
            // subslices can't be infinite
            return SliceableRange!(Range, withOpDollar, No.withInfiniteness)(arr[i .. j]);
        }

        static if (withInfiniteness)
        {
            enum empty = false;
        }
        else
        {
            @property bool empty() { return arr.empty; }
            @property auto length() { return arr.length; }
        }

        static if (withOpDollar)
        {
            static if (withInfiniteness)
            {
                struct Dollar {}
                Dollar opDollar() const { return Dollar.init; }

                //Slice to dollar
                typeof(this) opSlice(size_t lower, Dollar)
                {
                    return typeof(this)(arr[lower .. $]);
                }

            }
            else
            {
                alias opDollar = length;
            }
        }
    }

    alias T = int[];

    alias SliceableDummyRanges = AliasSeq!(
        DummyRange!(ReturnBy.Reference, Length.Yes, RangeType.Random, T),
        DummyRange!(ReturnBy.Value, Length.Yes, RangeType.Random, T),
        SliceableRange!(T, No.withOpDollar, No.withInfiniteness),
        SliceableRange!(T, Yes.withOpDollar, No.withInfiniteness),
        SliceableRange!(T, Yes.withOpDollar, Yes.withInfiniteness),
    );

    alias SliceableDummyRangesWithoutInfinity = AliasSeq!(
        DummyRange!(ReturnBy.Reference, Length.Yes, RangeType.Random, T),
        DummyRange!(ReturnBy.Value, Length.Yes, RangeType.Random, T),
        SliceableRange!(T, No.withOpDollar, No.withInfiniteness),
        SliceableRange!(T, Yes.withOpDollar, No.withInfiniteness),
    );

    static foreach (Partial; [Yes.withPartial, No.withPartial])
    {{
        static foreach (Range; SliceableDummyRanges)
        {{
            Range r;
            r.arr = 10.iota.array; // use a 0-based array (for clarity)

            static assert (isForwardRange!Range);
            enum hasSliceToEnd = hasSlicing!Range && is(typeof(Range.init[0 .. $]) == Range);

            assert(r.slide!Partial(2)[0].equal([0, 1]));
            assert(r.slide!Partial(2)[1].equal([1, 2]));

            // saveable
            auto s = r.slide!Partial(2);
            assert(s[0 .. 2].equal!equal([[0, 1], [1, 2]]));
            s.save.popFront;
            assert(s[0 .. 2].equal!equal([[0, 1], [1, 2]]));

            assert(r.slide!Partial(3)[1 .. 3].equal!equal([[1, 2, 3], [2, 3, 4]]));
        }}

        static foreach (Range; SliceableDummyRangesWithoutInfinity)
        {{
            static assert (hasSlicing!Range);
            static assert (hasLength!Range);

            Range r;
            r.arr = 10.iota.array; // use a 0-based array (for clarity)

            assert(r.slide!(No.withPartial)(6).equal!equal(
                [[0, 1, 2, 3, 4, 5], [1, 2, 3, 4, 5, 6], [2, 3, 4, 5, 6, 7],
                [3, 4, 5, 6, 7, 8], [4, 5, 6, 7, 8, 9]]
            ));
            assert(r.slide!(No.withPartial)(16).empty);

            assert(r.slide!Partial(4)[0 .. $].equal(r.slide!Partial(4)));
            assert(r.slide!Partial(2)[$/2 .. $].equal!equal([[4, 5], [5, 6], [6, 7], [7, 8], [8, 9]]));
            assert(r.slide!Partial(2)[$ .. $].empty);

            assert(r.slide!Partial(3).retro.equal!equal(
                [[7, 8, 9], [6, 7, 8], [5, 6, 7], [4, 5, 6], [3, 4, 5], [2, 3, 4], [1, 2, 3], [0, 1, 2]]
            ));
        }}

        // separate checks for infinity
        auto infIndex = SliceableRange!(T, No.withOpDollar, Yes.withInfiniteness)([0, 1, 2, 3]);
        assert(infIndex.slide!Partial(2)[0].equal([0, 1]));
        assert(infIndex.slide!Partial(2)[1].equal([1, 2]));

        auto infDollar = SliceableRange!(T, Yes.withOpDollar, Yes.withInfiniteness)();
        assert(infDollar.slide!Partial(2)[1 .. $].front.equal([1, 2]));
        assert(infDollar.slide!Partial(4)[0 .. $].front.equal([0, 1, 2, 3]));
        assert(infDollar.slide!Partial(4)[2 .. $].front.equal([2, 3, 4, 5]));
    }}
}
