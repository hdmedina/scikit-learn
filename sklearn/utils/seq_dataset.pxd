"""Dataset abstractions for sequential data access. """

cimport numpy as np

from cpython cimport bool

ctypedef np.float64_t DOUBLE
ctypedef np.int32_t INTEGER


cdef class SequentialDataset:
    cdef Py_ssize_t n_samples
    cdef np.ndarray norms
    cdef int current_index

    cdef void next(self, DOUBLE **x_data_ptr, INTEGER **x_ind_ptr,
                   int *nnz, DOUBLE *y, DOUBLE *sample_weight)
    cdef void shuffle(self, seed)
    cdef void precompute_norms(self, bool square=*)
    cdef double get_norm(self)


cdef class ArrayDataset(SequentialDataset):
    cdef Py_ssize_t n_features
    cdef int stride
    cdef DOUBLE *X_data_ptr
    cdef DOUBLE *Y_data_ptr
    cdef np.ndarray feature_indices
    cdef INTEGER *feature_indices_ptr
    cdef np.ndarray index
    cdef INTEGER *index_data_ptr
    cdef DOUBLE *sample_weight_data

    cdef void next(self, DOUBLE **x_data_ptr, INTEGER **x_ind_ptr,
                   int *nnz, DOUBLE *y, DOUBLE *sample_weight)
    cdef void shuffle(self, seed)
    cdef void precompute_norms(self, bool square=*)
    cdef double get_norm(self)


cdef class CSRDataset(SequentialDataset):
    cdef int stride
    cdef DOUBLE *X_data_ptr
    cdef INTEGER *X_indptr_ptr
    cdef INTEGER *X_indices_ptr
    cdef DOUBLE *Y_data_ptr
    cdef np.ndarray feature_indices
    cdef INTEGER *feature_indices_ptr
    cdef np.ndarray index
    cdef INTEGER *index_data_ptr
    cdef DOUBLE *sample_weight_data

    cdef void next(self, DOUBLE **x_data_ptr, INTEGER **x_ind_ptr,
                   int *nnz, DOUBLE *y, DOUBLE *sample_weight)
    cdef void shuffle(self, seed)
    cdef void precompute_norms(self, bool square=*)
    cdef double get_norm(self)
