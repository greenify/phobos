void main()
{
    import std.range, std.algorithm, std.functional, std.stdio;
    6.iota
      .filter!(a => a % 2) // 0 2 4
      .map!(a => a * 2) // 0 4 8
      .tee!writeln
      .sum
      .reverseArgs!writefln("Sum: %d");
}
