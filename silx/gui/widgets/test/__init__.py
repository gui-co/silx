# coding: utf-8
# /*##########################################################################
#
# Copyright (c) 2016-2018 European Synchrotron Radiation Facility
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
# ###########################################################################*/
import unittest

from . import test_periodictable
from . import test_tablewidget
from . import test_threadpoolpushbutton
from . import test_hierarchicaltableview
from . import test_printpreview
from . import test_framebrowser

__authors__ = ["V. Valls", "P. Knobel"]
__license__ = "MIT"
__date__ = "19/07/2017"


def suite():
    test_suite = unittest.TestSuite()
    test_suite.addTests(
        [test_threadpoolpushbutton.suite(),
         test_tablewidget.suite(),
         test_periodictable.suite(),
         test_printpreview.suite(),
         test_hierarchicaltableview.suite(),
         test_framebrowser.suite(),
         ])
    return test_suite
