import std.range;
import std.stdio;
import std.traits : Unqual;

public import std.typecons : Flag, Yes, No;

/**
This range iterates over a fixed-sized sliding window (k-mers)
of size `windowSize` of a `source` range.
$(D Source) must be at least an `InputRange` and
the `windowSize` must be greater than zero.
For `windowSize = 1` it splits the range into one element groups.
For `windowSize = 2` it is similar to `zip(source, source.save.dropOne)`.

If the Range is a mere `InputRange` (it doesn't support saving its state
nor has a length), extra allocation is required.

Params:
    slidesWithLessElements = If `Yes.slidesWithLessElements` slides  with fewer
        elements than `windowSize`. This can only happen if the initial range
        contains less elements than `windowSize`. In this case
        if `No.slidesWithLessElements` an empty range will be returned.
    r = Range from which the slides will be selected
    windowSize = Sliding window size
    stepSize = Steps between the windows

See_Also: $(LREF chunks)

Returns: Range of all sliding windows with propagated bidirectionality,
         forwarding, conditional random access and slicing.
*/
auto slides(Flag!"slidesWithLessElements" slidesWithLessElements = Yes.slidesWithLessElements,
            Source)(Source source, size_t windowSize, size_t stepSize = 1)
    if (isInputRange!Source)
{
    static if (isForwardRange!Source)
    {
        return Slides!(slidesWithLessElements, Source)(source, windowSize, stepSize);
    }
    else
    {
        // fallback struct - it uses a buffer and is more expensive
        return InputSlides!(slidesWithLessElements, Source)(source, windowSize, stepSize);
    }
}

private struct Slides(Flag!"slidesWithLessElements" slidesWithLessElements = Yes.slidesWithLessElements, Source)
    if (isForwardRange!Source)
{
private:
    Source _source;
    size_t _windowSize;
    size_t _stepSize;

    static if (hasLength!Source)
    {
        enum needsEndTracker = false;
    }
    else
    {
        // if there's no information about the length, track needs to be kept manually
        private Source _nextSource;
        enum needsEndTracker = true;
    }

    private bool _empty;

    static if (hasSlicing!Source)
    {
        private enum hasSliceToEnd = hasSlicing!Source && is(typeof(Source.init[0 .. $]) == Source);
    }

public:
    /// Standard constructor
    this(Source source, size_t windowSize, size_t stepSize)
    {
        assert(windowSize > 0, "windowSize must be greater than zero");
        assert(stepSize > 0, "stepSize must be greater than zero");
        _source = source;
        _windowSize = windowSize;
        _stepSize = stepSize;

        static if (needsEndTracker)
        {
            // _nextSource is used to "look into the future" and check for the end
            _nextSource = source.save;
            _nextSource.popFrontN(windowSize);
        }

        static if (!slidesWithLessElements)
        {
            // empty source range is needed, s.t. length, slicing etc. works properly
            static if (needsEndTracker)
            {
                if (_nextSource.empty)
                {
                    _source = _nextSource;
                }
            }
            else
            {
                if (_source.length < windowSize)
                {
                    static if (hasSlicing!Source)
                    {
                        static if (hasSliceToEnd)
                            _source = _source[$ .. $];
                        else
                            _source = _source[_source.length .. _source.length];
                    }
                    else
                    {
                        _source.popFrontN(_source.length);
                    }
                }
            }
        }

        _empty = _source.empty;
    }

    /// Forward range primitives. Always present.
    @property auto front()
    {
        assert(!empty);
        static if (hasSlicing!Source && hasLength!Source)
        {
            immutable len = _source.length;
            immutable end = (len > _windowSize) ? _windowSize : len;
            return _source[0 .. end];
        }
        else
        {
            return _source.save.take(_windowSize);
        }
    }

    /// Ditto
    void popFront()
    {
        assert(!empty);
        _source.popFrontN(_stepSize);

        static if (needsEndTracker)
        {
            if (_nextSource.empty)
                _empty = true;
            else
                _nextSource.popFrontN(_stepSize);
        }
        else
        {
            if (_source.length < _windowSize)
                _empty = true;
        }
    }

    static if (!isInfinite!Source)
    {
        /// Ditto
        @property bool empty()
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
        return typeof(this)(_source.save, _windowSize, _stepSize);
    }

    static if (hasLength!Source)
    {
        /// Length. Only if $(D hasLength!Source) is $(D true)
        @property size_t length()
        {
            if (_windowSize > _source.length)
            {
                static if (slidesWithLessElements)
                    return 1;
                else
                    return 0;
            }
            else
            {
                import std.math : ceil;
                double t = _source.length - _windowSize + 1;
                return cast(size_t) ceil(t / _stepSize);
            }
        }
    }

    static if (hasSlicing!Source)
    {
        /**
        Indexing and slicing operations. Provided only if
        $(D hasSlicing!Source) is $(D true).
         */
        static if (isInfinite!Source)
        {
            auto opIndex(size_t index)
            {
                return _source[index * _stepSize .. index * _stepSize + _windowSize];
            }
        }
        else static if (hasLength!Source)
        {
            auto opIndex(size_t index)
            {
                import std.algorithm : min;

                immutable start = index * _stepSize;
                immutable end   = start + _windowSize;
                immutable len = _source.length;
                assert(start < len, "slides index out of bounds");
                return _source[start .. min(end, len)];
            }
        }
        // hasSlicing implies either isInfinite or hasLength
        //else static if (hasSliceToEnd)
        //{
            //auto opIndex(size_t index)
            //{
                //return _source[index .. $].take(windowSize);
            //}
        //}

        /// Ditto
        static if (hasLength!Source)
        {
            typeof(this) opSlice(size_t lower, size_t upper)
            {
                import std.algorithm : min;
                assert(lower <= upper && upper <= length, "slides slicing index out of bounds");

                lower *= _stepSize;
                upper *= _stepSize;

                immutable len = _source.length;
                // notice that we only need to move for windowSize - 1 to the right
                // as the step size is 1
                // [0, 1, 2, 3] - slides(2) -> [[0, 1], [1, 2], [2, 3]]
                // [0, 1, 2, 3] - slides(3) -> [[0, 1, 2], [1, 2, 3]]
                return typeof(this)(_source[min(lower, len) .. min(upper + _windowSize - 1, len)], _windowSize, _stepSize);
            }
        }
        else static if (hasSliceToEnd)
        {
            //For slicing an infinite chunk, we need to slice the source to the end.
            auto opSlice(size_t lower, size_t upper)
            {
                assert(lower <= upper, "slides slicing index out of bounds");

                lower *= _stepSize;
                upper *= _stepSize;

                return typeof(this)(_source[lower .. $], _windowSize, _stepSize).takeExactly(upper - lower);
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
                    lower *= _stepSize;
                    return typeof(this)(_source[lower .. $], _windowSize, _stepSize);
                }
            }
        }
        else
        {
            alias ThisType = typeof(this);

            //Dollar token carries a static type, with no extra information.
            //It can lazily transform into _source.length on algorithmic
            //operations such as : slides[$/2, $-1];
            private static struct DollarToken
            {
                ThisType* mom;
                @property size_t momLength()
                {
                    return mom.length;
                }
                alias momLength this;
            }

            DollarToken opDollar()
            {
                return DollarToken(&this);
            }

            // Optimized slice overloads optimized for using dollar.
            typeof(this) opSlice(DollarToken, DollarToken)
            {
                static if (hasSliceToEnd)
                {
                    return typeof(this)(_source[$ .. $], _windowSize, _stepSize);
                }
                else
                {
                    immutable len = _source.length;
                    return typeof(this)(_source[len .. len], _windowSize, _stepSize);
                }
            }

            // Optimized slice overloads optimized for using dollar.
            typeof(this) opSlice(size_t lower, DollarToken)
            {
                import std.algorithm : min;
                assert(lower <= length, "slides slicing index out of bounds");
                lower *= _stepSize;
                static if (hasSliceToEnd)
                {
                    return typeof(this)(_source[min(lower, _source.length) .. $], _windowSize, _stepSize);
                }
                else
                {
                    immutable len = _source.length;
                    return typeof(this)(_source[min(lower, len) .. len], _windowSize, _stepSize);
                }
            }

            // Optimized slice overloads optimized for using dollar.
            typeof(this) opSlice(DollarToken, size_t upper)
            {
                assert(upper == length, "slides slicing index out of bounds");
                return this[$ .. $];
            }
        }
    }

    // Bidirectional range primitives
    static if (hasSlicing!Source && hasLength!Source)
    {
        /**
        Bidirectional range primitives. Provided only if both
        $(D hasSlicing!Source) and $(D hasLength!Source) are $(D true).
         */
        @property auto back()
        {
            import std.algorithm : max;
            assert(!empty, "back called on empty slides");
            immutable len = _source.length;

            size_t step = (len - _windowSize)  % _stepSize;
            //start -= _windowSize;
            immutable start = (len > _windowSize) ? len - _windowSize : 0;

            static if (hasSliceToEnd)
                return _source[start - step.. $ - step];
            else
                return _source[start - step .. len - step];
        }

        /// Ditto
        void popBack()
        {
            assert(!empty, "popBack() called on empty slides");
            static if (isBidirectionalRange!Source)
            {
                _source.popBackN(_stepSize);
            }
            else
            {
                static if (hasSliceToEnd)
                    _source = _source[0 .. $ - _stepSize];
                else
                    _source = _source[0 .. _source.length - _stepSize];
            }

            if (_source.length < _windowSize)
                _empty = true;
        }
    }
}

///
@safe pure nothrow unittest
{
    import std.array : array;
    import std.algorithm.comparison : equal;
    import std.algorithm.iteration : each;

    auto arr = [0, 1, 2, 3].slides(2);
    assert(arr[0] == [0, 1]);
    assert(arr[1] == [1, 2]);
    assert(arr[2] == [2, 3]);
    assert(arr.length == 3);

    assert(iota(5).slides(2).front.equal([0, 1]));
}

/// count k-mers
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;
    import std.algorithm.iteration : each;

    int[dstring] d;
    "AGAGA"d.slides(2).each!(a => d[a]++);
    assert(d == ["AG"d: 2, "GA"d: 2]);
}

@safe pure nothrow unittest
{
    import std.array : array;
    import std.algorithm.comparison : equal;
    import std.algorithm.iteration : each, map;

    // different window sizes
    assert([0, 1, 2, 3].slides(1).array == [[0], [1], [2], [3]]);
    assert([0, 1, 2, 3].slides(2).array == [[0, 1], [1, 2], [2, 3]]);
    assert([0, 1, 2, 3].slides(3).array == [[0, 1, 2], [1, 2, 3]]);
    assert([0, 1, 2, 3].slides(4).array == [[0, 1, 2, 3]]);
    assert([0, 1, 2, 3].slides(5).array == [[0, 1, 2, 3]]);

    // with iota
    assert(iota(2).slides(2).front.equal([0, 1]));
    assert(iota(3).slides(2).equal!equal([[0, 1],[1, 2]]));
    assert(iota(3).slides(3).equal!equal([[0, 1, 2]]));
    assert(iota(3).slides(4).equal!equal([[0, 1, 2]]));
    assert(iota(1, 4).slides(1).equal!equal([[1], [2], [3]]));
    assert(iota(1, 4).slides(3).equal!equal([[1, 2, 3]]));

    // check with empty input
    int[] d;
    assert(d.slides(2).empty);

    // is copyable?
    auto e = iota(5).slides(2);
    e.popFront;
    assert(e.save.equal!equal([[1, 2], [2, 3], [3, 4]]));
    assert(e.save.equal!equal([[1, 2], [2, 3], [3, 4]]));
    assert(e.map!"a.array".array == [[1, 2], [2, 3], [3, 4]]);

    // test with strings
    int[dstring] f;
    "AGAGA"d.slides(3).each!(a => f[a]++);
    assert(f == ["AGA"d: 2, "GAG"d: 1]);
}

// test slicing, length
//@safe pure nothrow unittest
unittest
{
    import std.array : array;
    import std.algorithm.comparison : equal;

    // test index
    assert(iota(3).slides(4)[0].equal([0, 1, 2]));
    assert(iota(5).slides(4)[1].equal([1, 2, 3, 4]));

    // test slicing
    assert(iota(3).slides(4)[0 .. $].equal!equal([[0, 1, 2]]));
    assert(iota(3).slides(2)[1 .. $].equal!equal([[1, 2]]));
    assert(iota(1, 5).slides(2)[0 .. 1].equal!equal([[1, 2]]));
    assert(iota(1, 5).slides(2)[0 .. 2].equal!equal([[1, 2], [2, 3]]));
    assert(iota(1, 5).slides(3)[0 .. 1].equal!equal([[1, 2, 3]]));
    assert(iota(1, 5).slides(3)[0 .. 2].equal!equal([[1, 2, 3], [2, 3, 4]]));
    assert(iota(1, 6).slides(3)[2 .. 3].equal!equal([[3, 4, 5]]));
    assert(iota(1, 5).slides(4)[0 .. 1].equal!equal([[1, 2, 3, 4]]));

    // length
    assert(iota(3).slides(3).length == 1);
    assert(iota(3).slides(2).length == 2);
    assert(iota(3).slides(1).length == 3);

    // opDollar
    assert(iota(3).slides(4)[$/2 .. $].equal!equal([[0, 1, 2]]));
    assert(iota(3).slides(4)[$ .. $].empty);
    assert(iota(3).slides(4)[$ .. 1].empty);
}

// test No.slidesWithLessElements
@safe pure nothrow unittest
{
    assert(iota(3).slides(4).length == 1);

    assert(iota(3).slides!(No.slidesWithLessElements)(4).empty);
    assert(iota(3).slides!(No.slidesWithLessElements)(4).length == 0);

    assert(iota(3).slides!(No.slidesWithLessElements)(400).empty);
    assert(iota(3).slides!(No.slidesWithLessElements)(400).length == 0);

    assert(iota(3).slides!(No.slidesWithLessElements)(4)[0 .. $].empty);
    assert(iota(3).slides!(No.slidesWithLessElements)(4)[$ .. $].empty);
    assert(iota(3).slides!(No.slidesWithLessElements)(4)[$ .. 0].empty);
    assert(iota(3).slides!(No.slidesWithLessElements)(4)[$/2 .. $].empty);
}

// test with infinite ranges
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    // InfiniteRange without RandomAccess
    auto fibsByPairs = recurrence!"a[n-1] + a[n-2]"(1, 1).slides(2);
    assert(fibsByPairs.take(2).equal!equal([[1,  1], [1,  2]]));

    // InfiniteRange with RandomAccess and slicing
    auto odds = sequence!("a[0] + n * a[1]")(1, 2);
    auto oddsByPairs = odds.slides(2);
    assert(oddsByPairs.take(2).equal!equal([[ 1,  3], [ 3,  5]]));
    assert(oddsByPairs[1].equal([3, 5]));
    assert(oddsByPairs[4].equal([9, 11]));

    static assert(hasSlicing!(typeof(odds)));
    assert(oddsByPairs[3 .. 5].equal!equal([[7, 9], [9, 11]]));
    assert(oddsByPairs[3 .. $].take(2).equal!equal([[7, 9], [9, 11]]));
}

// test reverse
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    auto e = iota(3).slides(2);
    assert(e.retro.equal!equal([[1, 2], [0, 1]]));
    assert(e.retro.array.equal(e.array.retro));

    auto e2 = iota(5).slides(3);
    assert(e2.retro.equal!equal([[2, 3, 4], [1, 2, 3], [0, 1, 2]]));
    assert(e2.retro.array.equal(e2.array.retro));

    auto e3 = iota(3).slides(4);
    assert(e3.retro.equal!equal([[0, 1, 2]]));
    assert(e3.retro.array.equal(e3.array.retro));
}

// step size
unittest
{
    import std.algorithm.comparison : equal;

    assert(iota(7).slides(2, 2).equal!equal([[0, 1], [2, 3], [4, 5]]));
    assert(iota(8).slides(2, 2).equal!equal([[0, 1], [2, 3], [4, 5], [6, 7]]));
    assert(iota(9).slides(2, 2).equal!equal([[0, 1], [2, 3], [4, 5], [6, 7]]));
    assert(iota(12).slides(2, 4).equal!equal([[0, 1], [4, 5], [8, 9]]));
    assert(iota(13).slides(2, 4).equal!equal([[0, 1], [4, 5], [8, 9]]));
}

// test with dummy ranges
@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;
    import std.internal.test.dummyrange : DummyRange, Length, RangeType, ReturnBy, AllDummyRanges;
    import std.meta : AliasSeq;

    foreach (Range; AliasSeq!AllDummyRanges)
    {
        Range r;
        assert(r.slides(1).equal!equal(
            [[1], [2], [3], [4], [5], [6], [7], [8], [9], [10]]
        ));
        assert(r.slides(2).equal!equal(
            [[1, 2], [2, 3], [3, 4], [4, 5], [5, 6], [6, 7], [7, 8], [8, 9], [9, 10]]
        ));
        assert(r.slides(3).equal!equal(
            [[1, 2, 3], [2, 3, 4], [3, 4, 5], [4, 5, 6],
            [5, 6, 7], [6, 7, 8], [7, 8, 9], [8, 9, 10]]
        ));
        assert(r.slides(6).equal!equal(
            [[1, 2, 3, 4, 5, 6], [2, 3, 4, 5, 6, 7], [3, 4, 5, 6, 7, 8],
            [4, 5, 6, 7, 8, 9], [5, 6, 7, 8, 9, 10]]
        ));
        assert(r.slides(15).equal!equal(
            [[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]]
        ));

        assert(r.slides!(No.slidesWithLessElements)(15).empty);
    }

    alias BackwardsDummyRanges = AliasSeq!(
        DummyRange!(ReturnBy.Reference, Length.Yes, RangeType.Random),
        DummyRange!(ReturnBy.Value, Length.Yes, RangeType.Random),
    );

    foreach (Range; AliasSeq!BackwardsDummyRanges)
    {
        Range r;
        assert(r.slides(1).retro.equal!equal(
            [[10], [9], [8], [7], [6], [5], [4], [3], [2], [1]]
        ));
        assert(r.slides(2).retro.equal!equal(
            [[9, 10], [8, 9], [7, 8], [6, 7], [5, 6], [4, 5], [3, 4], [2, 3], [1, 2]]
        ));
        assert(r.slides(5).retro.equal!equal(
            [[6, 7, 8, 9, 10], [5, 6, 7, 8, 9], [4, 5, 6, 7, 8],
            [3, 4, 5, 6, 7], [2, 3, 4, 5, 6], [1, 2, 3, 4, 5]]
        ));
        assert(r.slides(15).retro.equal!equal(
            [[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]]
        ));

        // different step size
        assert(r.slides(2, 4)[2].equal([9, 10]));
        assert(r.slides(2, 1).equal!equal(
            [[1, 2], [2, 3], [3, 4], [4, 5], [5, 6], [6, 7], [7, 8], [8, 9], [9, 10]]
        ));
        assert(r.slides(2, 2).equal!equal(
            [[1, 2], [3, 4], [5, 6], [7, 8], [9, 10]]
        ));
        assert(r.slides(2, 3).equal!equal(
            [[1, 2], [4, 5], [7, 8]]
        ));
        assert(r.slides(2, 4).equal!equal(
            [[1, 2], [5, 6], [9, 10]]
        ));

        assert(iota(1, 12).slides(2, 4)[0..3].equal!equal([[1, 2], [5, 6], [9, 10]]));
        assert(iota(1, 12).slides(2, 4)[0..$].equal!equal([[1, 2], [5, 6], [9, 10]]));
        assert(iota(1, 12).slides(2, 4)[$/2..$].equal!equal([[5, 6], [9, 10]]));

        // reverse
        assert(iota(1, 12).slides(2, 4).retro.equal!equal([[9, 10], [5, 6], [1, 2]]));
    }
}

// test different sliceable ranges
unittest
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

    foreach (Range; AliasSeq!SliceableDummyRanges)
    {
        Range r;
        r.arr = 10.iota.array; // for clarity

        static assert (isForwardRange!Range);
        enum hasSliceToEnd = hasSlicing!Range && is(typeof(Range.init[0 .. $]) == Range);

        assert(r.slides(2)[0].equal([0, 1]));
        assert(r.slides(2)[1].equal([1, 2]));

        // saveable
        auto s = r.slides(2);
        assert(s[0 .. 2].equal!equal([[0, 1], [1, 2]]));
        s.save.popFront;
        assert(s[0 .. 2].equal!equal([[0, 1], [1, 2]]));

        assert(r.slides(3)[1 .. 3].equal!equal([[1, 2, 3], [2, 3, 4]]));
    }

    alias SliceableDummyRangesWithoutInfinity = AliasSeq!(
        DummyRange!(ReturnBy.Reference, Length.Yes, RangeType.Random, T),
        DummyRange!(ReturnBy.Value, Length.Yes, RangeType.Random, T),
        SliceableRange!(T, No.withOpDollar, No.withInfiniteness),
        SliceableRange!(T, Yes.withOpDollar, No.withInfiniteness),
    );

    foreach (Range; AliasSeq!SliceableDummyRangesWithoutInfinity)
    {
        static assert (hasSlicing!Range);
        static assert (hasLength!Range);

        Range r;
        r.arr = 10.iota.array; // for clarity

        assert(r.slides!(No.slidesWithLessElements)(6).equal!equal(
            [[0, 1, 2, 3, 4, 5], [1, 2, 3, 4, 5, 6], [2, 3, 4, 5, 6, 7],
            [3, 4, 5, 6, 7, 8], [4, 5, 6, 7, 8, 9]]
        ));
        assert(r.slides!(No.slidesWithLessElements)(16).empty);

        assert(r.slides(4)[0 .. $].equal(r.slides(4)));
        assert(r.slides(2)[$/2 .. $].equal!equal([[4, 5], [5, 6], [6, 7], [7, 8], [8, 9]]));
        assert(r.slides(2)[$ .. $].empty);

        assert(r.slides(3).retro.equal!equal(
            [[7, 8, 9], [6, 7, 8], [5, 6, 7], [4, 5, 6], [3, 4, 5], [2, 3, 4], [1, 2, 3], [0, 1, 2]]
        ));
    }

    // separate checks for infinity
    auto infIndex = SliceableRange!(T, No.withOpDollar, Yes.withInfiniteness)([0, 1, 2, 3]);
    assert(infIndex.slides(2)[0].equal([0, 1]));
    assert(infIndex.slides(2)[1].equal([1, 2]));

    auto infDollar = SliceableRange!(T, Yes.withOpDollar, Yes.withInfiniteness)();
    assert(infDollar.slides(2)[1 .. $].front.equal([1, 2]));
    assert(infDollar.slides(4)[0 .. $].front.equal([0, 1, 2, 3]));
    assert(infDollar.slides(4)[2 .. $].front.equal([2, 3, 4, 5]));
}

// special buffered type for sole input ranges
private struct InputSlides(Flag!"slidesWithLessElements" slidesWithLessElements = Yes.slidesWithLessElements, Source)
    if (isInputRange!Source)
{
private:
    SlidingRangeBuffer!Source _buf;
    size_t _windowSize;
    size_t _stepSize;
    private bool _empty;

public:
    /// Standard constructor
    this(Source source, size_t windowSize, size_t stepSize)
    {
        assert(windowSize > 0, "windowSize must be greater than zero");
        assert(stepSize > 0, "stepSize must be greater than zero");
        _windowSize = windowSize;
        _stepSize = stepSize;

        _buf = typeof(_buf)(source, windowSize);

       // an empty source range is needed, s.t. length etc. works properly
        static if (!slidesWithLessElements)
            _empty = _buf.length < windowSize;
        else
            _empty = _buf.empty;
    }

    /// Forward range primitives. Always present.
    @property auto front()
    {
        return _buf.front;
    }

    /// Ditto
    void popFront()
    {
        assert(!_buf.empty);
        _buf.popFrontN(_stepSize);

        if (_buf.empty)
            _empty = true;
    }

    static if (!isInfinite!Source)
    {
        /// Ditto
        @property bool empty()
        {
            return _empty;
        }
    }
    else
    {
        // undocumented
        enum empty = false;
    }
}

// Simple range buffer, not exposed for now
private auto slidingRangeBuffer(Range)(Range r, size_t bufferSize)
{
    return SlidingRangeBuffer!Range(r, bufferSize);
}

// ditto, not exposed
private struct SlidingRangeBuffer(Range)
{
    import std.container.dlist : DList;
private:
    Range r;
    DList!(Unqual!(ElementType!Range)) buf;
    size_t _length;
    bool _empty;

public:

    ///
    this(Range r, size_t bufferSize)
    {
        assert(bufferSize > 0, "bufferSize must be greater than zero");

        this.r = r;
        this._empty = r.empty;
        this._length = bufferSize;

        foreach (i; 0 .. bufferSize)
        {
            if (this.r.empty)
            {
                this._length = i;
                break;
            }
            this.buf.insertBack(this.r.front);
            this.r.popFront;
        }
    }

    ///
    @property auto front()
    {
        return buf[];
    }

    ///
    void popFront()
    {
        this.buf.removeFront;

        if (this.r.empty)
        {
            _empty = true;
        }
        else
        {
            this.buf.insertBack(this.r.front);
            this.r.popFront;
        }
    }

    ///
    @property size_t length()
    {
        return _length;
    }

    ///
    @property bool empty()
    {
        return _empty;
    }
}

@safe pure nothrow unittest
{
    import std.internal.test.dummyrange : ReferenceInputRange;
    import std.algorithm.comparison : equal;

    auto arr = new ReferenceInputRange!int(5.iota.array);
    static assert(!isForwardRange!(typeof(arr)));
    auto buf = arr.slidingRangeBuffer(3);

    assert(buf.equal!equal([[0, 1, 2], [1, 2, 3], [2, 3, 4]]));
}

@safe pure nothrow unittest
{
    import std.algorithm.comparison : equal;

    struct StructInputRange(Range)
    {
        private Range _r;
        this(Range)(Range r) if (isInputRange!Range) {_r = r;}
        @property ElementType!Range front(){return _r.front;}
        void popFront(){_r.popFront();}
        @property bool empty(){return _r.empty;}
    }

    auto arr = StructInputRange!(int[])([0, 1, 2, 3, 4]);
    static assert(!isForwardRange!(typeof(arr)));
    auto buf = arr.slidingRangeBuffer(3);

    assert(buf.equal!equal([[0, 1, 2], [1, 2, 3], [2, 3, 4]]));
}
