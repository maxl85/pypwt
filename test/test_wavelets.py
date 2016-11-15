#!/usr/bin/env python
# -*- coding: utf-8 -*-


# This test file should be rewritten one day:
# - One class instead of two classes for 1D/2D
# - test DWT/SWT with different sizes (non-squares images, odd sizes)
#    but pywavelets does not handle odd sizes for swt
# - test inverse DWT and inverse SWT wrt input data
# - do all the aforementioned tests in the non-separable mode
# - test batched 1D transform. The comparison with pywavelets can be slow, though
#    recent versions of pywavelets have an "axis" property
# - note that pywt version >= 0.4   is 5-6 times faster !
#

import sys
import unittest
import logging
import numpy as np
from time import time
from testutils import available_filters

try:
    import pywt
except ImportError:
    print("ERROR : could not find the python module pywt")
    sys.exit(1)
try:
    from pypwt import Wavelets
except ImportError:
    print("ERROR: could not load pypwt. Make sure it is installed (python setup.py install --user)")
    sys.exit(1)
try:
    from scipy.misc import ascent
    scipy_img = ascent()
except ImportError:
    from scipy.misc import lena
    scipy_img = lena()


# Version <= 0.5 of PyWavelets uses the word "periodization"
# for the dwt extension mode, instead of "per" for nigma/pywt version.
# These are not compatibible for now.
try:
    pywt_ver_full = pywt.version.full_version
    v = pywt_ver_full.split(".")
    pywt_ver = float(v[0]) + 10**-(len(v[1]))*float(v[1])
    per_kw = "periodization"
except AttributeError: # nigma/pywt
    per_kw = "per"
    pywt_ver = -1.0
    pywt_ver_full = "?"



# Logging
logging.basicConfig(filename='results.log', filemode='w',
    format='%(asctime)s %(levelname)s %(message)s',
    datefmt='%m/%d/%Y %I:%M:%S', level=logging.DEBUG)
# -----



def elapsed_ms(t0):
    return (time()-t0)*1e3

def _calc_errors(arr1, arr2, string=None):
    if string is None: string = ""
    maxerr = np.max(np.abs(arr1 - arr2))
    msg = str("%s max error: %e" % (string, maxerr))
    logging.info(msg)
    return maxerr

# http://eli.thegreenplace.net/2011/08/02/python-unit-testing-parametrized-test-cases/
class ParametrizedTestCase(unittest.TestCase):
    """ TestCase classes that want to be parametrized should
        inherit from this class.
    """
    def __init__(self, methodName='runTest', param=None):
        super(ParametrizedTestCase, self).__init__(methodName)
        self.param = param

    @staticmethod
    def parametrize(testcase_klass, param=None):
        """ Create a suite containing all tests taken from the given
            subclass, passing them the parameter 'param'.
        """
        testloader = unittest.TestLoader()
        testnames = testloader.getTestCaseNames(testcase_klass)
        suite = unittest.TestSuite()
        for name in testnames:
            suite.addTest(testcase_klass(name, param=param))
        return suite


class TestWavelet(ParametrizedTestCase):


    def setUp(self):
        """
        Set up the TestWavelet class with default parameters.
        """
        # Maximum acceptable error wrt pywt for float32 precision.
        # As the transform are not scaled, the error increases with
        # the number of levels. Thus, self.tol is multiplied with 2**levels
        self.tol = 3e-4
        self.data = scipy_img
        #~ logging.info("Data shape: %s" % str(self.data.shape))

        # Default arguments when testing only one wavelet
        self.wname = "haar"
        self.levels = 8

        #~ logging.info("Data shape: %s" % str(self.data.shape))

        # Bind names to methods
        self.tests = {
            "dwt2": self.dwt2,
            #~ "idwt2": self.idwt2,
            #~ "swt2": self.swt2,
            #~ "iswt2": self.iswt2,
            #~ "dwt": self.dwt,
            #~ "idwt": self.idwt,
            #~ "swt": self.swt,
            #~ "iswt": self.iswt,
        }


    def test_wavelet(self):
        """
        Method which is actually executed when the test in launched.
        An additional parameter can be passed: param=..., where:
            param[0]: wavelet name
            param[1]: number of levels
            param[2]: input data
            param[3]: what to do ("dwt2", "idwt2", "swt2", "iswt2", "dwt", "idwt", "swt", "iswt"
            param[4]: separable mode for pypwt (default is True)
        """
        if self.param is None:
            wname = self.wname
            levels = self.levels
            data = self.data
            what = "dwt2"
            separable = 1
        else:
            wname = self.param[0]
            levels = self.param[1]
            data = self.param[2]
            what = self.param[3]
            separable = self.param[4]


        # Force an appropriate value for levels
        levels = min(levels, int(np.log2(min(data.shape)//pywt.Wavelet(wname).dec_len)))

        # Build the pywt Wavelet instance
        if "swt" in what: do_swt = 1
        else: do_swt = 0
        if "2" in what: ndim = 2
        else: ndim = 1
        W = Wavelets(data, wname, levels, do_separable=separable, do_swt=do_swt, ndim=ndim)

        # Run the test
        if what not in self.tests:
            raise ValueError("Unknown test %s" % what)
        logging.info("%s Testing %s%s with %s, %d levels %s" % ("-"*5, what, data.shape, wname, levels, "-"*5))
        self.tests[what](W, data, wname, levels)

        """
        logging.info("%s Testing %s with %s, %d levels %s" % ("-"*10, what, wname, levels, "-"*10))
        logging.info("computing Wavelets from pypwt")
        t0 = time()
        W.forward()
        logging.info("Wavelets.forward() took %.3f ms" % elapsed_ms(t0))
        logging.info("computing Wavelets from pywt")
        t0 = time()
        if not(do_swt):
            Wpy = pywt.wavedec2(self.data, wname, mode="per", level=levels)
        else:
            Wpy = pywt.swt2(self.data, wname, levels)
        logging.info("pywt took %.3f ms" % elapsed_ms(t0))

        self.compare_coeffs(W, Wpy, swt=bool(do_swt))
        """



    def dwt2(self, W, data, wname, levels):
        """
        Test pypwt against pywt for DWT2 (wavedec2).
        """
        # Forward DWT2 with pypwt
        logging.info("computing Wavelets from pypwt")
        t0 = time()
        W.forward()
        logging.info("Wavelets.forward() took %.3f ms" % elapsed_ms(t0))

        # Forward DWT2 with pywt
        logging.info("computing Wavelets from pywt")
        Wpy = pywt.wavedec2(data, wname, mode=per_kw, level=levels)
        logging.info("pywt took %.3f ms" % elapsed_ms(t0))

        # Compare results
        # FIXME: Error increases when levels increase, since output is scaled.
        tol = self.tol * 2**levels

        W_coeffs = W.coeffs
        if (levels != W.levels):
            err_msg = str("compare_coeffs(): pypwt instance has %d levels while pywt instance has %d levels" % (W.levels, levels))
            logging.error(err_msg)
            raise ValueError(err_msg)
        A = Wpy[0]
        maxerr = _calc_errors(A, W_coeffs[0], "[app]")
        self.assertTrue(maxerr < tol, msg="[%s] something wrong with the approximation coefficients (%d levels) (errmax = %e)" % (wname, levels, maxerr))
        for i in range(levels): # wavedec2 format
            # FIXME: Error increases when levels increase, since output is scaled.
            tol = self.tol * 2**(i+1)

            D1, D2, D3 = Wpy[levels-i][0], Wpy[levels-i][1], Wpy[levels-i][2]
            logging.info("%s Level %d %s" % ("-"*5, i+1, "-"*5))
            maxerr = _calc_errors(D1, W_coeffs[i+1][0], "[det.H]")
            self.assertTrue(maxerr < tol, msg="[%s] something wrong with the detail coefficients 1 at level %d (errmax = %e)" % (wname, i+1, maxerr))
            maxerr = _calc_errors(D2, W_coeffs[i+1][1], "[det.V]")
            self.assertTrue(maxerr < tol, msg="[%s] something wrong with the detail coefficients 2 at level %d (errmax = %e)" % (wname, i+1, maxerr))
            maxerr = _calc_errors(D3, W_coeffs[i+1][2], "[det.D]")
            self.assertTrue(maxerr < tol, msg="[%s] something wrong with the detail coefficients 3 at level %d (errmax = %e)" % (wname, i+1, maxerr))



    def idwt2(self, W, data, wname, levels):
        """
        Test pypwt against pywt for DWT2 (wavedec2).
        """
        # Forward DWT2 with pypwt
        logging.info("computing Wavelets from pypwt")
        t0 = time()
        W.forward()
        logging.info("Wavelets.forward() took %.3f ms" % elapsed_ms(t0))

        # Forward DWT2 with pywt
        logging.info("computing Wavelets from pywt")
        Wpy = pywt.wavedec2(data, wname, mode=per_kw, level=levels)
        logging.info("pywt took %.3f ms" % elapsed_ms(t0))

        # Compare results
        W_coeffs = W.coeffs
        if (levels != W.levels):
            err_msg = str("compare_coeffs(): pypwt instance has %d levels while pywt instance has %d levels" % (W.levels, levels))
            logging.error(err_msg)
            raise ValueError(err_msg)
        A = Wpy[0]
        maxerr = _calc_errors(A, W_coeffs[0], "[app]")
        self.assertTrue(maxerr < self.tol, msg="[%s] something wrong with the approximation coefficients (errmax = %e)" % (wname, maxerr))
        for i in range(levels): # wavedec2 format
            D1, D2, D3 = Wpy[levels-i][0], Wpy[levels-i][1], Wpy[levels-i][2]
            logging.info("%s Level %d %s" % ("-"*5, i+1, "-"*5))
            maxerr = _calc_errors(D1, W_coeffs[i+1][0], "[det.H]")
            self.assertTrue(maxerr < self.tol, msg="[%s] something wrong with the detail coefficients 1 at level %d (errmax = %e)" % (wname, i+1, maxerr))
            maxerr = _calc_errors(D2, W_coeffs[i+1][1], "[det.V]")
            self.assertTrue(maxerr < self.tol, msg="[%s] something wrong with the detail coefficients 2 at level %d (errmax = %e)" % (wname, i+1, maxerr))
            maxerr = _calc_errors(D3, W_coeffs[i+1][2], "[det.D]")
            self.assertTrue(maxerr < self.tol, msg="[%s] something wrong with the detail coefficients 3 at level %d (errmax = %e)" % (wname, i+1, maxerr))










    def compare_coeffs(self, W, Wpy, swt=False):
        """
        Compares the coefficients of pydwt to those of pywt.

        W: pypwt.Wavelets instance
        Wpy: pywt coefficients (wavedec2 or swt2)
        swt: boolean
        """
        wname = W.wname
        # retrieve all coefficients from GPU
        W_coeffs = W.coeffs


        if not(swt): # standard DWT
            levels = len(Wpy)-1
            if (levels != W.levels):
                err_msg = str("compare_coeffs(): pypwt instance has %d levels while pywt instance has %d levels" % (W.levels, levels))
                logging.error(err_msg)
                raise ValueError(err_msg)
            A = Wpy[0]
            maxerr = _calc_errors(A, W_coeffs[0], "[app]")
            self.assertTrue(maxerr < self.tol, msg="[%s] something wrong with the approximation coefficients (errmax = %e)" % (wname, maxerr))
            for i in range(levels):
                D1, D2, D3 = Wpy[levels-i][0], Wpy[levels-i][1], Wpy[levels-i][2]
                logging.info("%s Level %d %s" % ("-"*5, i+1, "-"*5))
                maxerr = _calc_errors(D1, W_coeffs[i+1][0], "[det.H]")
                self.assertTrue(maxerr < self.tol, msg="[%s] something wrong with the detail coefficients 1 at level %d (errmax = %e)" % (wname, i+1, maxerr))
                maxerr = _calc_errors(D2, W_coeffs[i+1][1], "[det.V]")
                self.assertTrue(maxerr < self.tol, msg="[%s] something wrong with the detail coefficients 2 at level %d (errmax = %e)" % (wname, i+1, maxerr))
                maxerr = _calc_errors(D3, W_coeffs[i+1][2], "[det.D]")
                self.assertTrue(maxerr < self.tol, msg="[%s] something wrong with the detail coefficients 3 at level %d (errmax = %e)" % (wname, i+1, maxerr))

        else: # SWT
            levels = len(Wpy)
            if (levels != W.levels):
                err_msg = str("compare_coeffs(): pypwt instance has %d levels while pywt instance has %d levels" % (W.levels, levels))
                logging.error(err_msg)
                raise ValueError(err_msg)
            for i in range(levels):
                A, D1, D2, D3 = Wpy[levels-1-i][0], Wpy[levels-1-i][1][0], Wpy[levels-1-i][1][1], Wpy[levels-1-i][1][2]
                logging.info("%s Level %d %s" % ("-"*5, i+1, "-"*5))
                _calc_errors(D1, W_coeffs[i+1][0], "[det.H]")
                _calc_errors(D2, W_coeffs[i+1][1], "[det.V]")
                _calc_errors(D3, W_coeffs[i+1][2], "[det.D]")












def dwt1_batched(testwavelet):
    if pywt_ver < 0.5:
        raise RuntimeError("Batched 1D DWT is only available from PyWavelets 0.5")
    # ...
















def test_suite_all_wavelets():
    print("Testing all the %d available filters [2D]" % len(available_filters))
    testSuite = unittest.TestSuite()
    maxlev = 2 # beware of filter size reducing the possible number of levels
    for wname in available_filters:
        testSuite.addTest(ParametrizedTestCase.parametrize(TestWavelet2D, param=(wname, 2, 0)))
    return testSuite


def test_suite_wavelet2D():
    testSuite = unittest.TestSuite()
    testSuite.addTest(ParametrizedTestCase.parametrize(TestWavelet2D, param=("haar", 8, 0)))
    #~ testSuite.addTest(ParametrizedTestCase.parametrize(TestWavelet2D, param=("rbio3.1", 3, 0)))
    return testSuite


def test_suite_wavelet1D():
    testSuite = unittest.TestSuite()
    data = np.ascontiguousarray(lena()[0])
    testSuite.addTest(ParametrizedTestCase.parametrize(TestWavelet1D, param=("haar", 8, 0, data)))
    return testSuite



def test_suite_all_wavelets1D():
    print("Testing all the %d available filters [1D]" % len(available_filters))
    testSuite = unittest.TestSuite()
    maxlev = 2 # beware of filter size reducing the possible number of levels
    data = np.ascontiguousarray(lena()[0])
    for wname in available_filters:
        testSuite.addTest(ParametrizedTestCase.parametrize(TestWavelet1D, param=(wname, 2, 0, data)))
    return testSuite


def test_dwt2():
    testSuite = unittest.TestSuite()

    data = scipy_img
    levels = 4
    params = ["",  levels, data, "dwt2", 1]
    for wname in available_filters:
        #~ params[0] = wname
        testSuite.addTest(ParametrizedTestCase.parametrize(TestWavelet, param=[wname, levels, data, "dwt2", 1]))
    return testSuite




if __name__ == '__main__':
    if pywt_ver < 0: pywt_ver = "?"
    v_str = str("Using pypwt version %s and pywavelets version %s" % (Wavelets.version(), str(pywt_ver_full)))
    logging.info(v_str)
    print(v_str)
    #~ mysuite = test_suite_wavelet2D()
    #~ mysuite = test_suite_all_wavelets()
    mysuite = test_dwt2()




    runner = unittest.TextTestRunner()
    runner.run(mysuite)




