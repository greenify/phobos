/*
    Regualar expressions package test suite.
*/
module std.regex.internal.tests.tests4;

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
        TestVectors(  "a.*c",      "axyzc","y",    "$&",    "axyzc" ),
        TestVectors(  "a.*c",      "axyzd","n",    "-",    "-" ),
        TestVectors(  "a[bc]d",    "abc",  "n",    "-",    "-" ),
        TestVectors(  "a[bc]d",    "abd",  "y",    "$&",    "abd" ),
        TestVectors(  "a[b-d]e",   "abd",  "n",    "-",    "-" ),
        TestVectors(  "a[b-d]e",   "ace",  "y",    "$&",    "ace" ),
        TestVectors(  "a[b-d]",    "aac",  "y",    "$&",    "ac" ),
        TestVectors(  "a[-b]",     "a-",   "y",    "$&",    "a-" ),
        TestVectors(  "a[b-]",     "a-",   "y",    "$&",    "a-" ),
        TestVectors(  "a[b-a]",    "-",    "c",    "-",    "-" ),
    ];
    runTests!tv;
}
