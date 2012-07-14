# encoding: utf-8
# cython: cdivision=True
# cython: boundscheck=False
# cython: wraparound=False
#
# Author: Peter Prettenhofer, Brian Holt, Gilles Louppe
#
# License: BSD Style.

cimport cython

import numpy as np
cimport numpy as np

# Define a datatype for the data array
DTYPE = np.float64
ctypedef np.float64_t DTYPE_t
ctypedef np.int8_t BOOL_t

cdef extern from "math.h":
    cdef extern double log(double x)
    cdef extern double pow(double base, double exponent)

cdef extern from "float.h":
    cdef extern double DBL_MAX


################################################################################
# Classification entropy measures
#
#    From Hastie et al. Elements of Statistical Learning, 2009.
#
#    If a target is a classification outcome taking on values 0,1,...,K-1
#    In node m, representing a region Rm with Nm observations, let
#
#       pmk = 1/ Nm \sum_{x_i in Rm} I(yi = k)
#
#    be the proportion of class k observations in node m

cdef class Criterion:
    """Interface for splitting criteria (regression and classification)"""

    cdef void init(self, DTYPE_t[:,:,:,:] y, BOOL_t *sample_mask, int n_samples,
                   int n_total_samples):
        """Initialise the criterion class for new split point."""
        pass

    cdef void reset(self):
        """Reset the criterion for a new feature index."""
        pass

    cdef int update(self, int a, int b, DTYPE_t[:,:,:,:] y, int *X_argsorted_i,
                    BOOL_t *sample_mask):
        """Update the criteria for each value in interval [a,b) (where a and b
           are indices in `X_argsorted_i`)."""
        pass

    cdef double eval(self):
        """Evaluate the criteria (aka the split error)."""
        pass

    cpdef np.ndarray init_value(self):
        """Get the init value of the criterion - `init` must be called before."""
        pass


cdef class ClassificationCriterion(Criterion):
    """Abstract criterion for classification.

    Attributes
    ----------
    n_classes : int
        The number of classes.

    n_samples : int
        The number of samples.

    label_count_left : int*
        The label counts for samples left of splitting point.

    label_count_right : int*
        The label counts for samples right of splitting point.

    label_count_init : int*
        The initial label counts for samples right of splitting point.
        Used to reset `label_count_right` for each feature.

    n_left : int
        The number of samples left of splitting point.

    n_right : int
        The number of samples right of splitting point.
    """
    cdef int n_classes
    cdef int n_samples
    cdef int* label_count_left
    cdef int* label_count_right
    cdef int* label_count_init
    cdef int n_left
    cdef int n_right

    # need to store ref to arrays to prevent GC
    cdef ndarray_label_count_left
    cdef ndarray_label_count_right
    cdef ndarray_label_count_init

    def __init__(self, int n_classes):
        cdef np.ndarray[np.int32_t, ndim=1] ndarray_label_count_left \
            = np.zeros((n_classes,), dtype=np.int32, order='C')
        cdef np.ndarray[np.int32_t, ndim=1] ndarray_label_count_right \
            = np.zeros((n_classes,), dtype=np.int32, order='C')
        cdef np.ndarray[np.int32_t, ndim=1] ndarray_label_count_init \
            = np.zeros((n_classes,), dtype=np.int32, order='C')

        self.n_classes = n_classes
        self.n_samples = 0
        self.n_left = 0
        self.n_right = 0
        self.label_count_left = <int*>ndarray_label_count_left.data
        self.label_count_right = <int*>ndarray_label_count_right.data
        self.label_count_init = <int*>ndarray_label_count_init.data
        self.ndarray_label_count_left = ndarray_label_count_left
        self.ndarray_label_count_right = ndarray_label_count_right
        self.ndarray_label_count_init = ndarray_label_count_init

    cdef void init(self, DTYPE_t[:,:,:,:] y, BOOL_t *sample_mask, int n_samples,
                   int n_total_samples):
        """Initialise the criterion class."""
        cdef int c = 0
        cdef int j = 0

        self.n_samples = n_samples

        for c from 0 <= c < self.n_classes:
            self.label_count_init[c] = 0

        for j from 0 <= j < n_total_samples:
            if sample_mask[j] == 0:
                continue
            c = <int>(y[j,0,0,0])
            self.label_count_init[c] += 1

        self.reset()

    cdef void reset(self):
        """Reset label_counts by setting `label_count_left to zero
        and copying the init array into the right."""
        cdef int c = 0
        self.n_left = 0
        self.n_right = self.n_samples

        for c from 0 <= c < self.n_classes:
            self.label_count_left[c] = 0
            self.label_count_right[c] = self.label_count_init[c]

    cdef int update(self, int a, int b, DTYPE_t[:,:,:,:] y, int *X_argsorted_i,
                    BOOL_t *sample_mask):
        """Update the criteria for each value in interval [a,b) (where a and b
           are indices in `X_argsorted_i`)."""
        cdef int c
        # post condition: all samples from [0:b) are on the left side
        for idx from a <= idx < b:
            s = X_argsorted_i[idx]
            if sample_mask[s] == 0:
                continue
            c = <int>(y[s,0,0,0])
            self.label_count_right[c] -= 1
            self.label_count_left[c] += 1
            self.n_right -= 1
            self.n_left += 1

        return self.n_left

    cdef double eval(self):
        pass

    cpdef np.ndarray init_value(self):
        return self.ndarray_label_count_init


cdef class Gini(ClassificationCriterion):
    """Gini Index splitting criteria.

    Gini index = \sum_{k=0}^{K-1} pmk (1 - pmk)
               = 1 - \sum_{k=0}^{K-1} pmk ** 2
    """

    cdef double eval(self):
        """Returns Gini index of left branch + Gini index of right branch. """
        cdef double n_left = <double> self.n_left
        cdef double n_right = <double> self.n_right
        cdef double H_left = n_left * n_left
        cdef double H_right = n_right * n_right
        cdef int k, count_left, count_right

        for k from 0 <= k < self.n_classes:
            count_left = self.label_count_left[k]
            if count_left > 0:
                H_left -= (count_left * count_left)
            count_right = self.label_count_right[k]
            if count_right > 0:
                H_right -= (count_right * count_right)

        if n_left == 0:
            H_left = 0
        else:
            H_left /= n_left

        if n_right == 0:
            H_right = 0
        else:
            H_right /= n_right

        return (H_left + H_right) / self.n_samples


cdef class Entropy(ClassificationCriterion):
    """Entropy splitting criteria.

    Cross Entropy = - \sum_{k=0}^{K-1} pmk log(pmk)
    """

    cdef double eval(self):
        """Returns Entropy of left branch + Entropy index of right branch. """
        cdef double H_left = 0.0
        cdef double H_right = 0.0
        cdef int k
        cdef double e1, e2
        cdef double n_left = <double> self.n_left
        cdef double n_right = <double> self.n_right

        for k from 0 <= k < self.n_classes:
            if self.label_count_left[k] > 0:
                H_left -= ((self.label_count_left[k] / n_left)
                           * log(self.label_count_left[k] / n_left))
            if self.label_count_right[k] > 0:
                H_right -= ((self.label_count_right[k] / n_right)
                            * log(self.label_count_right[k] / n_right))

        e1 = (n_left / self.n_samples) * H_left
        e2 = (n_right / self.n_samples) * H_right
        return e1 + e2


cpdef double sse(double ss, double m, int n):
    return ss - <double>(n) * (m ** 2)


cdef class RegressionCriterion(Criterion):
    """Abstract criterion for regression. Computes variance of the
       target values left and right of the split point.

    Computation is linear in `n_samples` by using ::

        var = \sum_i^n (y_i - y_bar) ** 2
            = (\sum_i^n y_i ** 2) - n_samples y_bar ** 2

    Attributes
    ----------
    n_samples : int
        The number of samples

    sum_left : double

    sum_right : double

    sq_sum_left : double
        The sum of squared target values left of the split point.

    sq_sum_right : double
        The sum of squared target values right of the split point.

    n_left : int
        number of samples left of split point.

    n_right : int
        number of samples right of split point.
    """

    cdef int n_samples
    cdef int n_right
    cdef int n_left

    cdef DTYPE_t[:,:,:] mean_left
    cdef DTYPE_t[:,:,:] mean_right

    cdef DTYPE_t[:,:,:] var_left
    cdef DTYPE_t[:,:,:] var_right

    cdef DTYPE_t[:,:,:] mean_init

    cdef DTYPE_t[:,:,:] sq_sum_right
    cdef DTYPE_t[:,:,:] sq_sum_left
    cdef DTYPE_t[:,:,:] sq_sum_init

    cdef int y1
    cdef int y2
    cdef int y3

    def __init__(self):
        self.n_samples = 0
        self.n_left = 0
        self.n_right = 0

        self.y1 = 0
        self.y2 = 0
        self.y3 = 0

        mean_left = None
        mean_right = None

        var_left = None
        var_right = None

        mean_init = None

        sq_sum_right = None
        sq_sum_left = None
        sq_sum_init = None

        self.n_samples = 0


    cdef void init(self, DTYPE_t[:,:,:,:] y, BOOL_t *sample_mask, int n_samples,
                   int n_total_samples):
        """Initialise the criterion class; assume all samples
           are in the right branch and store the mean and squared
           sum in `self.mean_init` and `self.sq_sum_init`. """
        shape = (y.shape[1], y.shape[2], y.shape[3])
        self.y1 = y.shape[1]
        self.y2 = y.shape[2]
        self.y3 = y.shape[3]
        self.mean_left = np.zeros(shape, dtype=DTYPE)
        self.mean_right = np.zeros(shape, dtype=DTYPE)
        self.mean_init = np.zeros(shape, dtype=DTYPE)
        self.sq_sum_right = np.zeros(shape, dtype=DTYPE)
        self.sq_sum_left = np.zeros(shape, dtype=DTYPE)
        self.sq_sum_init = np.zeros(shape, dtype=DTYPE)
        self.var_left = np.zeros(shape, dtype=DTYPE)
        self.var_right = np.zeros(shape, dtype=DTYPE)
        self.n_samples = n_samples

        cdef int j = 0
        cdef int y1 = 0
        cdef int y2 = 0
        cdef int y3 = 0
        for j from 0 <= j < n_total_samples:
            if sample_mask[j] == 0:
                continue
            for y1 in range(y.shape[1]):
                for y2 in range(y.shape[2]):
                    for y3 in range(y.shape[3]):
                        y_idx = y[j, y1, y2, y3]
                        self.mean_init[y1, y2, y3] += y_idx
                        self.sq_sum_init[y1, y2, y3] += (y_idx * y_idx)


        for y1 in range(y.shape[1]):
            for y2 in range(y.shape[2]):
                for y3 in range(y.shape[3]):
                    self.mean_init[y1, y2, y3] /= n_samples
        self.reset()


    cdef void reset(self):
        """Reset criterion for new feature.

        Assume all data in right branch and copy statistics of the
        whole dataset into the auxiliary variables of the
        right branch.
        """
        self.n_right = self.n_samples
        self.n_left = 0
        self.mean_right[...] = self.mean_init
        self.mean_left[...] = 0.0
        self.sq_sum_right[...] = self.sq_sum_init
        self.sq_sum_left[...] = 0.0
        self.update_var()


    cdef int update(self, int a, int b, DTYPE_t[:,:,:,:] y, int *X_argsorted_i,
                    BOOL_t *sample_mask):
        """Update the criteria for each value in interval [a,b) (where a and b
           are indices in `X_argsorted_i`)."""
        cdef double y_idx = 0.0
        cdef int idx, j
        # post condition: all samples from [0:b) are on the left side
        for j in range(a, b):

            idx = X_argsorted_i[j]
            if sample_mask[idx] == 0:
                continue

            for y1 in range(y.shape[1]):
                for y2 in range(y.shape[2]):
                    for y3 in range(y.shape[3]):
                        y_idx = y[idx, y1, y2, y3]

                        self.sq_sum_left[y1, y2, y3] = self.sq_sum_left[y1, y2, y3] + (y_idx * y_idx)
                        self.sq_sum_right[y1, y2, y3] = self.sq_sum_right[y1, y2, y3] - (y_idx * y_idx)

                        self.mean_left[y1, y2, y3] = (self.n_left * self.mean_left[y1, y2, y3] + y_idx) / \
                            <double>(self.n_left + 1)

                        self.mean_right[y1, y2, y3] = ((self.n_samples - self.n_left) * \
                                                           self.mean_right[y1, y2, y3] - y_idx) / \
                                                           <double>(self.n_samples - self.n_left - 1)

                        self.n_right -= 1
                        self.n_left += 1
        self.update_var()
        return self.n_left


    cdef void update_var(self):
        for y1 in range(self.y1):
            for y2 in range(self.y2):
                for y3 in range(self.y3):
                    self.var_left[y1, y2, y3] = sse(self.sq_sum_left[y1, y2, y3],
                                                    self.mean_left[y1, y2, y3],
                                                    self.n_left)
                    self.var_right[y1, y2, y3] = sse(self.sq_sum_right[y1, y2, y3],
                                                     self.mean_right[y1, y2, y3],
                                                     self.n_right)


    cdef double eval(self):
        pass


    cpdef np.ndarray init_value(self):
        ## TODO is calling np.asarray a performance issue?
        shape = (self.y1, self.y2, self.y3)
        r = np.zeros(shape, dtype=DTYPE)
        cdef int i = 0
        cdef int j = 0
        cdef int k = 0
        for i from 0 <= i < self.y1:
            for j from 0 <= j < self.y2:
                for k from 0 <= k < self.y3:
                    r[i, j, k] = self.mean_init[i, j, k]
        return r


cdef class MSE(RegressionCriterion):
    """Mean squared error impurity criterion.

    MSE = var_left + var_right
    """

    cdef double eval(self):
        cdef double result_left = 0.0
        cdef double result_right = 0.0
        for y1 in range(self.y1):
            for y2 in range(self.y2):
                for y3 in range(self.y3):
                    result_left += self.var_left[y1, y2, y3]
                    result_right += self.var_right[y1, y2, y3]
        cdef double final = result_left + result_right
        return final


cpdef crit_init(Criterion c, DTYPE_t[:,:,:,:] y, np.ndarray sample_mask, int n_samples,
                   int n_total_samples):
    cdef BOOL_t *sample_mask_ptr = <BOOL_t *>sample_mask.data
    c.init(y, sample_mask_ptr, n_samples, n_total_samples)


cpdef int crit_update(Criterion c, int a, int b, DTYPE_t[:,:,:,:] y,
                      np.ndarray X_argsorted,
                      np.ndarray sample_mask):
    cdef BOOL_t *sample_mask_ptr = <BOOL_t *>sample_mask.data
    cdef int *X_argsorted_i = <int *>X_argsorted.data

    result = c.update(a, b, y, X_argsorted_i, sample_mask_ptr)

    return result


cpdef double crit_eval(Criterion c):
    return c.eval()



################################################################################
# Tree util functions
#


def _random_sample_mask(int n_total_samples, int n_total_in_bag, random_state):
    """Create a random sample mask where ``n_total_in_bag`` elements are set.

    Parameters
    ----------
    n_total_samples : int
        The length of the resulting mask.
    n_total_in_bag : int
        The number of elements in the sample mask which are set to 1.
    random_state : np.RandomState
        A numpy ``RandomState`` object.

    Returns
    -------
    sample_mask : np.ndarray, shape=[n_total_samples]
        An ndarray where ``n_total_in_bag`` elements are set to ``True``
        the others are ``False``.
    """
    cdef np.ndarray[np.float64_t, ndim=1, mode="c"] rand = \
         random_state.rand(n_total_samples)
    cdef np.ndarray[BOOL_t, ndim=1, mode="c"] sample_mask = \
         np.zeros((n_total_samples,), dtype=np.int8)

    cdef int n_bagged = 0
    cdef int i = 0
    for i in range(n_total_samples):
        if rand[i] * (n_total_samples - i) < (n_total_in_bag - n_bagged):
            sample_mask[i] = 1
            n_bagged += 1

    return sample_mask.astype(np.bool)


def _apply_tree(np.ndarray[DTYPE_t, ndim=2] X,
                np.ndarray[np.int32_t, ndim=2] children,
                np.ndarray[np.int32_t, ndim=1] feature,
                np.ndarray[np.float64_t, ndim=1] threshold,
                np.ndarray[np.int32_t, ndim=1] out):
    """Finds the terminal region (=leaf node) for each sample in
    `X` and sets the corresponding element in `out` to its node id."""
    cdef int i = 0
    cdef int n = X.shape[0]
    cdef int node_id = 0
    for i in xrange(n):
        node_id = 0
        # While node_id not a leaf
        while children[node_id, 0] != -1 and children[node_id, 1] != -1:
            if X[i, feature[node_id]] <= threshold[node_id]:
                node_id = children[node_id, 0]
            else:
                node_id = children[node_id, 1]
        out[i] = node_id


def _predict_tree(np.ndarray[DTYPE_t, ndim=2] X,
                  np.ndarray[np.int32_t, ndim=2] children,
                  np.ndarray[np.int32_t, ndim=1] feature,
                  np.ndarray[np.float64_t, ndim=1] threshold,
                  np.float64_t[:,:,:,:] values,
                  np.float64_t[:,:,:,:] pred):
    """Finds the terminal region (=leaf node) values for each sample. """
    cdef int i = 0
    cdef int n = X.shape[0]
    cdef int node_id = 0
    cdef int K = values.shape[1]
    for i in xrange(n):
        node_id = 0
        # While node_id not a leaf
        while children[node_id, 0] != -1 and children[node_id, 1] != -1:
            if X[i, feature[node_id]] <= threshold[node_id]:
                node_id = children[node_id, 0]
            else:
                node_id = children[node_id, 1]
        for y1 in range(values.shape[1]):
            for y2 in range(values.shape[2]):
                for y3 in range(values.shape[3]):
                    pred[i, y1, y2, y3] = values[node_id, y1, y2, y3]


def _error_at_leaf(np.ndarray[DTYPE_t, ndim=4, mode="c"] y,
                   np.ndarray sample_mask, Criterion criterion,
                   int n_samples):
    """Compute criterion error at leaf with terminal region defined
    by `sample_mask`. """
    cdef int n_total_samples = y.shape[0]
    cdef BOOL_t *sample_mask_ptr = <BOOL_t *>sample_mask.data
    criterion.init(y, sample_mask_ptr, n_samples, n_total_samples)
    return criterion.eval()


cdef int smallest_sample_larger_than(int sample_idx, DTYPE_t *X_i,
                                     int *X_argsorted_i, BOOL_t *sample_mask,
                                     int n_total_samples):
    """Find the largest next sample.

    Find the index in the `X_i` array for sample who's feature
    `i` value is just about greater than those of the sample
    `X_argsorted_i[sample_idx]`.

    Returns
    -------
    next_sample_idx : int
        The index of the next smallest sample in `X_argsorted`
        with different feature value than `sample_idx` .
        I.e. `X_argsorted_i[sample_idx] < X_argsorted_i[next_sample_idx]`
        -1 if no such element exists.
    """
    cdef int idx = 0, j
    cdef DTYPE_t threshold = -DBL_MAX

    if sample_idx > -1:
        threshold = X_i[X_argsorted_i[sample_idx]]

    for idx from sample_idx < idx < n_total_samples:
        j = X_argsorted_i[idx]

        if sample_mask[j] == 0:
            continue

        if X_i[j] > threshold + 1.e-7:
            return idx

    return -1


def _find_best_split(np.ndarray[DTYPE_t, ndim=2, mode="fortran"] X,
                     np.ndarray[DTYPE_t, ndim=4, mode="c"] y,
                     np.ndarray[np.int32_t, ndim=2, mode="fortran"] X_argsorted,
                     np.ndarray sample_mask,
                     int n_samples,
                     int min_leaf,
                     int max_features,
                     Criterion criterion,
                     object random_state):
    """Find the best dimension and threshold that minimises the error.

    Parameters
    ----------
    X : ndarray, shape (n_total_samples, n_features), dtype=DTYPE_t
        The feature values.

    y : ndarray, shape (n_total_samples,), dtype=float
        The label to predict for each sample.

    X_argsorted : ndarray, shape (n_samples, n_features)
        Argsort of cols of `X`. `X_argsorted[0,j]` gives the example
        index of the smallest value of feature `j`.

    sample_mask : ndarray, shape (n_samples,), dtype=np.bool
        A mask for the samples to be considered. Only samples `j` for which
        sample_mask[j] != 0 are considered.

    n_samples : int
        The number of samples in the current sample_mask
        (i.e. `sample_mask.sum()`).

    min_leaf : int
        The minimum number of samples required to be at a leaf node.

    max_features : int
        The number of features to consider when looking for the best split.

    criterion : Criterion
        The criterion function to be minimized.

    random_state : RandomState
        The numpy random state to use.

    Returns
    -------
    best_i : int
        The split feature or -1 if criterion not smaller than
        `parent_split_error`.

    best_t : DTYPE_t
        The split threshold

    best_error : DTYPE_t
        The split error

    initial_error : DTYPE_t
        The initial error contained in the node.
    """
    # Variables declarations
    cdef int n_total_samples = X.shape[0]
    cdef int n_features = X.shape[1]
    cdef int i, a, b, best_i = -1
    cdef np.int32_t feature_idx = -1
    cdef int n_left = 0
    cdef DTYPE_t t, initial_error, error
    cdef DTYPE_t best_error = np.inf, best_t = np.inf
    cdef DTYPE_t *X_i = NULL
    cdef int *X_argsorted_i = NULL
    cdef BOOL_t *sample_mask_ptr = <BOOL_t *>sample_mask.data
    cdef np.ndarray[np.int32_t, ndim=1, mode='c'] features = None

    # Compute the column strides (increment in pointer elements to get
    # from column i to i + 1) for `X` and `X_argsorted`
    cdef int X_elem_stride = X.strides[0]
    cdef int X_col_stride = X.strides[1]
    cdef int X_stride = X_col_stride / X_elem_stride
    cdef int X_argsorted_elem_stride = X_argsorted.strides[0]
    cdef int X_argsorted_col_stride = X_argsorted.strides[1]
    cdef int X_argsorted_stride = X_argsorted_col_stride / X_argsorted_elem_stride

    # Compute the initial criterion value in the node
    X_argsorted_i = <int *>X_argsorted.data
    criterion.init(y, sample_mask_ptr, n_samples, n_total_samples)
    initial_error = criterion.eval()

    if initial_error == 0:  # break early if the node is pure
        return best_i, best_t, initial_error, initial_error

    best_error = initial_error

    # Features to consider
    features = np.arange(n_features, dtype=np.int32)
    if max_features < 0 or max_features >= n_features:
        max_features = n_features
    else:
        features = random_state.permutation(features)[:max_features]

    # Look for the best split
    for feature_idx in range(max_features):
        i = features[feature_idx]
        # Get i-th col of X and X_sorted
        X_i = (<DTYPE_t *>X.data) + X_stride * i
        X_argsorted_i = (<int *>X_argsorted.data) + X_argsorted_stride * i

        # Reset the criterion for this feature
        criterion.reset()

        # Index of smallest sample in X_argsorted_i that is in the sample mask
        a = 0
        while sample_mask_ptr[X_argsorted_i[a]] == 0:
            a = a + 1

        # Consider splits between two consecutive samples
        while True:
            # Find the following larger sample
            b = smallest_sample_larger_than(a, X_i, X_argsorted_i,
                                            sample_mask_ptr, n_total_samples)
            if b == -1:
                break

            # Better split than the best so far?
            n_left = criterion.update(a, b, y, X_argsorted_i, sample_mask_ptr)

            # Only consider splits that respect min_leaf
            if n_left < min_leaf or (n_samples - n_left) < min_leaf:
                a = b
                continue

            error = criterion.eval()

            if error < best_error:
                t = X_i[X_argsorted_i[a]] + \
                    ((X_i[X_argsorted_i[b]] - X_i[X_argsorted_i[a]]) / 2.0)
                if t == X_i[X_argsorted_i[b]]:
                    t = X_i[X_argsorted_i[a]]
                best_i = i
                best_t = t
                best_error = error

            # Proceed to the next interval
            a = b

    return best_i, best_t, best_error, initial_error


def _find_best_random_split(np.ndarray[DTYPE_t, ndim=2, mode="fortran"] X,
                            np.ndarray[DTYPE_t, ndim=4, mode="c"] y,
                            np.ndarray[np.int32_t, ndim=2, mode="fortran"] X_argsorted,
                            np.ndarray sample_mask,
                            int n_samples,
                            int min_leaf,
                            int max_features,
                            Criterion criterion,
                            object random_state):
    """Find the best dimension and threshold that minimises the error.

    Parameters
    ----------
    X : ndarray, shape (n_total_samples, n_features), dtype=DTYPE_t
        The feature values.

    y : ndarray, shape (n_total_samples,), dtype=float
        The label to predict for each sample.

    X_argsorted : ndarray, shape (n_samples, n_features)
        Argsort of cols of `X`. `X_argsorted[0,j]` gives the example
        index of the smallest value of feature `j`.

    sample_mask : ndarray, shape (n_samples,), dtype=np.bool
        A mask for the samples to be considered. Only samples `j` for which
        sample_mask[j] != 0 are considered.

    n_samples : int
        The number of samples in the current sample_mask
        (i.e. `sample_mask.sum()`).

    min_leaf : int
        The minimum number of samples required to be at a leaf node.

    max_features : int
        The number of features to consider when looking for the best split.

    criterion : Criterion
        The criterion function to be minimized.

    random_state : RandomState
        The numpy random state to use.

    Returns
    -------
    best_i : int
        The split feature or -1 if criterion not smaller than
        `parent_split_error`.

    best_t : DTYPE_t
        The split threshold

    best_error : DTYPE_t
        The split error

    initial_error : DTYPE_t
        The initial error contained in the node.
    """
    # Variables
    cdef int n_total_samples = X.shape[0]
    cdef int n_features = X.shape[1]
    cdef int i, a, b, c, n_left, best_i = -1
    cdef np.int32_t feature_idx = -1
    cdef DTYPE_t t, initial_error, error
    cdef DTYPE_t best_error = np.inf, best_t = np.inf
    cdef DTYPE_t *X_i = NULL
    cdef int *X_argsorted_i = NULL
    cdef BOOL_t *sample_mask_ptr = <BOOL_t *>sample_mask.data
    cdef np.ndarray[np.int32_t, ndim=1, mode='c'] features = None

    # Compute the column strides (increment in pointer elements to get
    # from column i to i + 1) for `X` and `X_argsorted`
    cdef int X_elem_stride = X.strides[0]
    cdef int X_col_stride = X.strides[1]
    cdef int X_stride = X_col_stride / X_elem_stride
    cdef int X_argsorted_elem_stride = X_argsorted.strides[0]
    cdef int X_argsorted_col_stride = X_argsorted.strides[1]
    cdef int X_argsorted_stride = X_argsorted_col_stride / X_argsorted_elem_stride

    # Compute the initial criterion value
    X_argsorted_i = <int *>X_argsorted.data
    criterion.init(y, sample_mask_ptr, n_samples, n_total_samples)
    initial_error = criterion.eval()

    if initial_error == 0:  # break early if the node is pure
        return best_i, best_t, best_error, initial_error

    best_error = initial_error

    # Features to consider
    features = np.arange(n_features, dtype=np.int32)
    if max_features < 0 or max_features >= n_features:
        max_features = n_features
    else:
        features = random_state.permutation(features)[:max_features]

    # Look for the best random split
    for feature_idx in range(max_features):
        i = features[feature_idx]
        # Get i-th col of X and X_sorted
        X_i = (<DTYPE_t *>X.data) + X_stride * i
        X_argsorted_i = (<int *>X_argsorted.data) + X_argsorted_stride * i

        # Reset the criterion for this feature
        criterion.reset()

        # Find min and max
        a = 0
        while sample_mask_ptr[X_argsorted_i[a]] == 0:
            a = a + 1

        b = n_total_samples - 1
        while sample_mask_ptr[X_argsorted_i[b]] == 0:
            b = b - 1

        if b <= a or X_i[X_argsorted_i[a]] == X_i[X_argsorted_i[b]]:
            continue

        # Draw a random threshold in [a, b)
        t = X_i[X_argsorted_i[a]] + (random_state.rand() *
                                     (X_i[X_argsorted_i[b]] - X_i[X_argsorted_i[a]]))
        if t == X_i[X_argsorted_i[b]]:
            t = X_i[X_argsorted_i[a]]

        # Find the sample just greater than t
        c = a + 1

        while True:
            if sample_mask_ptr[X_argsorted_i[c]] != 0:
                if X_i[X_argsorted_i[c]] > t or c == b:
                    break

            c += 1

        # Better than the best so far?
        n_left = criterion.update(0, c, y, X_argsorted_i, sample_mask_ptr)
        error = criterion.eval()

        if n_left < min_leaf or (n_samples - n_left) < min_leaf:
            continue

        if error < best_error:
            best_i = i
            best_t = t
            best_error = error

    return best_i, best_t, best_error, initial_error
