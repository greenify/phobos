/*
    Regualar expressions package test suite.
*/
module std.regex.internal.tests.tests16;

package(std.regex):

import std.regex.internal.tests.common;

/* The test vectors in this file are altered from Henry Spencer's regexp
   test code. His copyright notice is:

        Copyright (c) 1986 by University of Toronto.
        Written by Henry Spencer.  Not derived from licensed software.

        Permission is granted to anyone to use this software for any
        purpose on any computer system, and to redistribute it freely,
        subject to the following restrictions:

        1. The author is not responsible for the consequences of use of
                this software, no matter how awful, even if they arise
                from defects in it.

        2. The origin of this software must not be misrepresented, either
                by explicit claim or by omission.

        3. Altered versions must be plainly marked as such, and must not
                be misrepresented as being the original software.
 */

@safe unittest
{
    static immutable TestVectors[] tv = [
        TestVectors(  "abc",       "ababc",                "y",    "$&",    "abc" ),
        TestVectors(  "apple(,)\\sorange\\1",      "apple, orange, cherry, peach", "y", "$&", "apple, orange," ),
        TestVectors(  "(\\w+)\\s(\\w+)",           "John Smith", "y", "$2, $1", "Smith, John" ),
        TestVectors(  "\\n\\f\\r\\t\\v",           "abc\n\f\r\t\vdef", "y", "$&", "\n\f\r\t\v" ),
        TestVectors(  ".*c",       "abcde",                        "y",    "$&",    "abc" ),
        TestVectors(  "^\\w+((;|=)\\w+)+$", "some=host=tld",    "y", "$&-$1-$2", "some=host=tld-=tld-=" ),
        TestVectors(  "^\\w+((\\.|-)\\w+)+$", "some.host.tld",    "y", "$&-$1-$2", "some.host.tld-.tld-." ),
        TestVectors(  "q(a|b)*q",  "xxqababqyy",                "y",    "$&-$1",        "qababq-b" ),
        TestVectors(  "^(a)(b){0,1}(c*)",   "abcc", "y", "$1 $2 $3", "a b cc" ),
        TestVectors(  "^(a)((b){0,1})(c*)", "abcc", "y", "$1 $2 $3", "a b b" ),
    ];
    runTests!tv;
}
