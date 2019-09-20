# distutils: language = c++
from pycalphad.core.composition_set cimport CompositionSet
cimport numpy as np
import numpy as np
from pycalphad.core.constants import MIN_SITE_FRACTION, MIN_PHASE_FRACTION, CHEMPOT_CONSTRAINT_SCALING
from pycalphad.core.constraints import get_multiphase_constraint_rhs
import pycalphad.variables as v

def _pinv_derivative(a, a_pinv, a_prime):
    """
    The derivative of a real valued pseudoinverse matrix can be specified
    in terms of the derivative of the original matrix.

    Reference
    ---------
    Golub, G. H.; Pereyra, V. (April 1973).
    "The Differentiation of Pseudo-Inverses and Nonlinear Least Squares Problems Whose Variables Separate".
    SIAM Journal on Numerical Analysis. 10 (2): 413–32. JSTOR 2156365.

    Parameters
    ----------
    a
    a_pinv
    a_prime

    Returns
    -------

    """
    result = np.zeros(a_pinv.shape + (a_prime.shape[2],))
    for dof_idx in range(a_prime.shape[2]):
        result[:,:, dof_idx] = -np.matmul(np.matmul(a_pinv, a_prime[:, :, dof_idx]), a_pinv)
        result[:,:, dof_idx] += np.matmul(np.matmul(np.matmul(a_pinv, a_pinv.T), a_prime.T[dof_idx]),
                                          (np.eye(a.shape[0]) - a @ a_pinv))
        result[:,:, dof_idx] += np.matmul(np.matmul(np.matmul((np.eye(a.shape[1]) - np.matmul(a_pinv, a)),
                                                              a_prime.T[dof_idx]), a_pinv.T), a_pinv)
    return result


cdef class Problem:
    def __init__(self, comp_sets, comps, conditions):
        cdef CompositionSet compset
        cdef int num_internal_cons = sum(compset.phase_record.num_internal_cons for compset in comp_sets)
        cdef int num_dpot_cons = sum(compset.phase_record.num_dpot_cons for compset in comp_sets)
        cdef object state_variables
        cdef int num_fixed_dof_cons
        cdef int num_constraints, num_chemical_potentials, num_gibbs_duhem
        cdef int constraint_idx = 0
        cdef int var_idx = 0
        cdef int value_idx
        cdef int phase_idx = 0
        cdef double indep_sum = sum([float(val) for i, val in conditions.items() if i.startswith('X_')])
        cdef object multiphase_rhs = get_multiphase_constraint_rhs(conditions)
        cdef object dependent_comp
        if len(comp_sets) == 0:
            raise ValueError('Number of phases is zero')
        state_variables = comp_sets[0].phase_record.state_variables
        fixed_statevars = [(key, value) for key, value in conditions.items() if key in [str(k) for k in state_variables]]

        self.composition_sets = comp_sets
        self.conditions = conditions
        desired_active_pure_elements = [list(x.constituents.keys()) for x in comps]
        desired_active_pure_elements = [el.upper() for constituents in desired_active_pure_elements for el in constituents]
        self.pure_elements = sorted(set(desired_active_pure_elements))
        self.nonvacant_elements = [x for x in self.pure_elements if x != 'VA']
        self.fixed_chempot_indices = np.array([self.nonvacant_elements.index(key[3:]) for key in conditions.keys() if key.startswith('MU_')], dtype=np.int32)
        self.fixed_chempot_values = np.array([float(value) for key, value in conditions.items() if key.startswith('MU_')])
        num_fixed_dof_cons = len(state_variables) + self.fixed_chempot_indices.shape[0]
        num_gibbs_duhem = len(self.composition_sets)
        num_constraints = num_fixed_dof_cons + num_internal_cons + num_dpot_cons + \
                          len(get_multiphase_constraint_rhs(conditions)) + num_gibbs_duhem
        num_chemical_potentials = len(self.nonvacant_elements)
        self.num_phases = len(self.composition_sets)
        self.num_vars = len(state_variables) + sum(compset.phase_record.phase_dof for compset in comp_sets) + self.num_phases + num_chemical_potentials
        self.num_internal_constraints = num_internal_cons
        self.num_fixed_dof_constraints = num_fixed_dof_cons
        self.num_dpot_constraints = num_dpot_cons
        self.fixed_dof_indices = np.zeros(self.num_fixed_dof_constraints, dtype=np.int32)
        self.fixed_dof_values = np.zeros(self.fixed_dof_indices.shape[0], dtype=np.float64)
        # TODO: Need to add phase fractions to support them as a fixed dof!
        all_dof = list(str(k) for k in state_variables)
        for compset in comp_sets:
            all_dof.extend(compset.phase_record.variables)
        for i, s in enumerate(fixed_statevars):
            k, v = s
            self.fixed_dof_indices[i] = all_dof.index(k)
            self.fixed_dof_values[i] = v
        for value_idx in range(len(fixed_statevars), num_fixed_dof_cons):
            self.fixed_dof_indices[value_idx] = self.num_vars - num_chemical_potentials + self.fixed_chempot_indices[value_idx - len(fixed_statevars)]
            self.fixed_dof_values[value_idx] = self.fixed_chempot_values[value_idx - len(fixed_statevars)]
        self.num_constraints = num_constraints
        # XXX: Are these large enough bounds for the chemical potential?
        # They need to be bounded somehow, or else they will run off to +- inf
        self.xl = np.r_[np.full(self.num_vars - self.num_phases - num_chemical_potentials, MIN_SITE_FRACTION),
                        np.full(self.num_phases, MIN_PHASE_FRACTION), np.full(num_chemical_potentials, -2e15)]
        self.xu = np.r_[np.ones(self.num_vars - self.num_phases - num_chemical_potentials)*2.e19,
                        np.ones(self.num_phases)*2e19, np.full(num_chemical_potentials, 2e15)]
        self.x0 = np.zeros(self.num_vars)
        for var_idx in range(len(state_variables)):
            self.x0[var_idx] = comp_sets[0].dof[var_idx]
        var_idx = len(state_variables)
        for compset in self.composition_sets:
            self.x0[var_idx:var_idx+compset.phase_record.phase_dof] = compset.dof[len(state_variables):]
            self.x0[self.num_vars-len(self.nonvacant_elements)-self.num_phases+phase_idx] = compset.NP
            var_idx += compset.phase_record.phase_dof
            phase_idx += 1
        self.cl = np.zeros(num_constraints)
        self.cu = np.zeros(num_constraints)
        compset = comp_sets[0]
        # Fixed dof
        for var_idx in range(num_fixed_dof_cons):
            self.cl[var_idx] = self.fixed_dof_values[var_idx]
            self.cu[var_idx] = self.fixed_dof_values[var_idx]
        for var_idx in range(num_fixed_dof_cons, num_internal_cons + num_fixed_dof_cons):
            self.cl[var_idx] = 0
            self.cu[var_idx] = 0
        for var_idx in range(num_fixed_dof_cons + num_internal_cons, num_internal_cons + num_fixed_dof_cons + num_dpot_cons):
            self.cl[var_idx] = 0
            self.cu[var_idx] = 0
        for var_idx in range(num_fixed_dof_cons + num_internal_cons + num_dpot_cons, num_fixed_dof_cons + num_internal_cons + num_dpot_cons + len(multiphase_rhs)):
            self.cl[var_idx] = multiphase_rhs[var_idx-num_internal_cons-num_fixed_dof_cons-num_dpot_cons]
            self.cu[var_idx] = multiphase_rhs[var_idx-num_internal_cons-num_fixed_dof_cons-num_dpot_cons]
        # Gibbs-Duhem for each phase
        for var_idx in range(num_fixed_dof_cons + num_internal_cons + num_dpot_cons + len(multiphase_rhs), num_constraints):
            self.cl[var_idx] = 0
            self.cu[var_idx] = 0

    def objective(self, x_in):
        cdef CompositionSet compset
        cdef int phase_idx = 0
        cdef double total_obj = 0
        cdef int var_offset = 0
        cdef int chempot_idx
        cdef int idx = 0
        cdef double[::1] x = np.array(x_in)
        cdef double tmp = 0
        cdef double mass_tmp = 0
        cdef double[:,::1] dof_2d_view = <double[:1,:x.shape[0]]>&x[0]
        cdef double[::1] energy_2d_view = <double[:1]>&tmp
        compset = self.composition_sets[0]
        var_offset = len(compset.phase_record.state_variables)

        for compset in self.composition_sets:
            x = np.r_[x_in[:len(compset.phase_record.state_variables)], x_in[var_offset:var_offset+compset.phase_record.phase_dof]]
            dof_2d_view = <double[:1,:x.shape[0]]>&x[0]
            compset.phase_record.obj(energy_2d_view, dof_2d_view)
            idx = 0
            total_obj += x_in[self.num_vars-len(self.nonvacant_elements)-self.num_phases+phase_idx] * tmp
            phase_idx += 1
            var_offset += compset.phase_record.phase_dof
            tmp = 0
        return total_obj

    def gradient(self, x_in):
        cdef CompositionSet compset = self.composition_sets[0]
        cdef int phase_idx
        cdef int num_statevars = len(compset.phase_record.state_variables)
        cdef int var_offset = num_statevars
        cdef int dof_x_idx, spidx
        cdef int idx = 0
        cdef double total_obj = 0
        cdef double[::1] x = np.array(x_in)
        cdef double tmp = 0
        cdef double mass_obj_tmp = 0
        cdef double[:,::1] dof_2d_view = <double[:1,:x.shape[0]]>&x[0]
        cdef double[::1] energy_2d_view = <double[:1]>&tmp
        cdef double[::1] grad_tmp = np.zeros(x.shape[0])
        cdef double[::1] out_mass_tmp = np.zeros(self.num_vars)
        cdef np.ndarray[ndim=1, dtype=np.float64_t] gradient_term = np.zeros(self.num_vars)

        for phase_idx in range(self.num_phases):
            compset = self.composition_sets[phase_idx]
            x = np.r_[x_in[:num_statevars], x_in[var_offset:var_offset+compset.phase_record.phase_dof]]
            spidx = self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx
            dof_2d_view = <double[:1,:x.shape[0]]>&x[0]
            compset.phase_record.obj(energy_2d_view, dof_2d_view)
            compset.phase_record.grad(grad_tmp, x)
            for dof_x_idx in range(num_statevars):
                gradient_term[dof_x_idx] += x_in[spidx] * grad_tmp[dof_x_idx]
            for dof_x_idx in range(compset.phase_record.phase_dof):
                gradient_term[var_offset + dof_x_idx] = \
                    x_in[spidx] * grad_tmp[num_statevars+dof_x_idx]
            idx = 0
            gradient_term[spidx] += tmp
            grad_tmp[:] = 0
            tmp = 0
            energy_2d_view = <double[:1]>&tmp
            var_offset += compset.phase_record.phase_dof
            phase_idx += 1

        gradient_term[np.isnan(gradient_term)] = 0
        return gradient_term

    def energy_gradient(self, x_in):
        cdef CompositionSet compset = self.composition_sets[0]
        cdef int phase_idx
        cdef int num_statevars = len(compset.phase_record.state_variables)
        cdef int var_offset = num_statevars
        cdef int dof_x_idx, spidx
        cdef int idx = 0
        cdef double total_obj = 0
        cdef double[::1] x = np.array(x_in)
        cdef double tmp = 0
        cdef double mass_obj_tmp = 0
        cdef double[:,::1] dof_2d_view = <double[:1,:x.shape[0]]>&x[0]
        cdef double[::1] energy_2d_view = <double[:1]>&tmp
        cdef double[::1] grad_tmp = np.zeros(x.shape[0])
        cdef double[::1] out_mass_tmp = np.zeros(self.num_vars)
        cdef np.ndarray[ndim=1, dtype=np.float64_t] gradient_term = np.zeros(self.num_vars)

        for phase_idx in range(self.num_phases):
            compset = self.composition_sets[phase_idx]
            x = np.r_[x_in[:num_statevars], x_in[var_offset:var_offset+compset.phase_record.phase_dof]]
            spidx = self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx
            dof_2d_view = <double[:1,:x.shape[0]]>&x[0]
            compset.phase_record.obj(energy_2d_view, dof_2d_view)
            compset.phase_record.grad(grad_tmp, x)
            for dof_x_idx in range(num_statevars):
                gradient_term[dof_x_idx] += x_in[spidx] * grad_tmp[dof_x_idx]
            for dof_x_idx in range(compset.phase_record.phase_dof):
                gradient_term[var_offset + dof_x_idx] = \
                    x_in[spidx] * grad_tmp[num_statevars+dof_x_idx]
            idx = 0
            gradient_term[spidx] += tmp
            grad_tmp[:] = 0
            tmp = 0
            energy_2d_view = <double[:1]>&tmp
            var_offset += compset.phase_record.phase_dof
            phase_idx += 1

        gradient_term[np.isnan(gradient_term)] = 0
        return gradient_term

    def obj_hessian(self, x_in):
        cdef CompositionSet compset = self.composition_sets[0]
        cdef size_t num_statevars = len(compset.phase_record.state_variables)
        cdef double[:, ::1] hess = np.zeros((self.num_vars, self.num_vars))
        cdef double[::1] hess_tmp = np.zeros((self.num_vars * self.num_vars))
        cdef double[::1] grad_tmp = np.zeros(self.num_vars)
        cdef double[:, ::1] hess_tmp_view
        cdef double[::1] x = np.array(x_in)
        cdef double[::1] x_tmp = np.zeros(x.shape[0])
        cdef double phase_frac = 0
        cdef size_t var_idx = 0
        cdef size_t phase_idx, grad_idx, cons_idx, dof_idx, sv_idx
        cdef size_t row, col
        cdef size_t constraint_offset = 0
        x_tmp[:num_statevars] = x[:num_statevars]
        var_idx = num_statevars
        for phase_idx in range(self.num_phases):
            compset = self.composition_sets[phase_idx]
            phase_frac = x[self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx]
            x_tmp[num_statevars:num_statevars+compset.phase_record.phase_dof] = \
                x[var_idx:var_idx+compset.phase_record.phase_dof]
            hess_tmp_view = <double[:num_statevars+compset.phase_record.phase_dof,
                                    :num_statevars+compset.phase_record.phase_dof]>&hess_tmp[0]
            compset.phase_record.grad(grad_tmp, x_tmp)
            compset.phase_record.hess(hess_tmp_view, x_tmp)
            for row in range(compset.phase_record.phase_dof):
                for col in range(compset.phase_record.phase_dof):
                    hess[var_idx+row, var_idx+col] = \
                        phase_frac * hess_tmp_view[num_statevars+row, num_statevars+col]
                    hess[var_idx+col, var_idx+row] = \
                        phase_frac * hess_tmp_view[num_statevars+row, num_statevars+col]
            for iter_idx in range(num_statevars):
                for dof_idx in range(compset.phase_record.phase_dof):
                    hess[iter_idx, var_idx + dof_idx] += \
                        phase_frac * hess_tmp_view[iter_idx, num_statevars + dof_idx]
                    hess[var_idx + dof_idx, iter_idx] += \
                        phase_frac * hess_tmp_view[iter_idx, num_statevars + dof_idx]
                for sv_idx in range(num_statevars):
                    hess[iter_idx, sv_idx] += \
                        phase_frac * hess_tmp_view[iter_idx, sv_idx]
                    if iter_idx != sv_idx:
                        hess[sv_idx, iter_idx] += \
                            phase_frac * hess_tmp_view[iter_idx, sv_idx]
            # wrt phase_frac
            for dof_idx in range(compset.phase_record.phase_dof):
                hess[self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx, var_idx + dof_idx] = grad_tmp[num_statevars+dof_idx]
                hess[var_idx + dof_idx, self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx] = grad_tmp[num_statevars+dof_idx]
            for sv_idx in range(num_statevars):
                hess[self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx, sv_idx] = grad_tmp[sv_idx]
                hess[sv_idx, self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx] = grad_tmp[sv_idx]
            hess_tmp[:] = 0
            grad_tmp[:] = 0
            x_tmp[num_statevars:] = 0
            var_idx += compset.phase_record.phase_dof
        return np.array(hess)

    def hessian(self, x_in, lagrange, obj_factor):
        cdef CompositionSet compset = self.composition_sets[0]
        cdef int num_statevars = len(compset.phase_record.state_variables)
        cdef double[:, ::1] hess = obj_factor * self.obj_hessian(x_in)
        cdef double[::1] constraint_hess_tmp = np.zeros(self.num_constraints * self.num_vars * self.num_vars)
        cdef double[:, :, ::1] constraint_hess_tmp_view
        cdef double[::1] lmul = lagrange
        cdef double[::1] x = np.array(x_in)
        cdef double[::1] x_tmp = np.zeros(x.shape[0])
        cdef double[::1] hess_tmp = np.zeros((self.num_vars * self.num_vars))
        cdef double[::1] grad_tmp = np.zeros(self.num_vars)
        cdef double[:, ::1] hess_tmp_view
        cdef double[::1] chempots = np.zeros(len(self.nonvacant_elements))
        cdef double[::1] moles = np.zeros(len(self.nonvacant_elements))
        cdef double[::1] moles_view
        cdef double[:, ::1] moles_gradient = np.zeros((len(self.nonvacant_elements), self.num_vars))
        cdef double[::1] moles_gradient_view
        cdef double[:, :, ::1] moles_hessian = np.zeros((len(self.nonvacant_elements), self.num_vars, self.num_vars))
        cdef double[::1] moles_hessian_tmp = np.zeros((self.num_vars * self.num_vars))
        cdef double[:, ::1] moles_hessian_view
        cdef double[::1] energy_out = np.atleast_1d(np.zeros(1,  dtype=np.float64))
        cdef double[:, ::1] dof_2d_view
        cdef double[::1] energy_gradient = np.zeros(self.num_vars)
        cdef int constraint_offset = 0
        cdef int var_idx = 0
        cdef int idx, phase_idx, idx_row, idx_col, iter_idx, cons_idx, spidx
        cdef size_t chempot_idx = self.num_vars - chempots.shape[0]

        chempots[:] = x[-len(self.nonvacant_elements):]

        x_tmp[:num_statevars] = x[:num_statevars]
        # First: Fixed degree of freedom constraints (linear)
        constraint_offset += self.num_fixed_dof_constraints

        # Second: Phase internal constraints
        var_idx = num_statevars
        for phase_idx in range(self.num_phases):
            compset = self.composition_sets[phase_idx]
            x_tmp[num_statevars:num_statevars+compset.phase_record.phase_dof] = \
                x[var_idx:var_idx+compset.phase_record.phase_dof]
            constraint_hess_tmp_view = <double[:compset.phase_record.num_internal_cons,
                                               :num_statevars+compset.phase_record.phase_dof,
                                               :num_statevars+compset.phase_record.phase_dof]>&constraint_hess_tmp[0]
            compset.phase_record.internal_cons_hessian(constraint_hess_tmp_view, x_tmp)
            for cons_idx in range(compset.phase_record.num_internal_cons):
                for idx_row in range(num_statevars):
                    for idx_col in range(idx_row, num_statevars):
                        hess[idx_row, idx_col] += lmul[constraint_offset + cons_idx] * \
                                                  constraint_hess_tmp_view[cons_idx, idx_row, idx_col]
                        if idx_row != idx_col:
                            hess[idx_col, idx_row] += lmul[constraint_offset + cons_idx] * \
                                                    constraint_hess_tmp_view[cons_idx, idx_col, idx_row]
                for idx_row in range(compset.phase_record.phase_dof):
                    for idx_col in range(idx_row, compset.phase_record.phase_dof):
                        hess[var_idx + idx_row, var_idx + idx_col] += lmul[constraint_offset + cons_idx] * \
                                                  constraint_hess_tmp_view[cons_idx, num_statevars+idx_row, num_statevars+idx_col]
                        if idx_row != idx_col:
                            hess[var_idx + idx_col, var_idx + idx_row] += lmul[constraint_offset + cons_idx] * \
                                                  constraint_hess_tmp_view[cons_idx, num_statevars+idx_col, num_statevars+idx_row]
            # No phase fraction contribution, by definition
            constraint_hess_tmp[:] = 0
            x_tmp[num_statevars:] = 0
            var_idx += compset.phase_record.phase_dof
            constraint_offset += compset.phase_record.num_internal_cons

        # Third: Diffusion potential constraints
        var_idx = num_statevars
        for phase_idx in range(self.num_phases):
            compset = self.composition_sets[phase_idx]
            spidx = self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx
            x_tmp[num_statevars:num_statevars+compset.phase_record.phase_dof] = \
                x[var_idx:var_idx+compset.phase_record.phase_dof]
            x_tmp[num_statevars+compset.phase_record.phase_dof] = x[spidx]
            x_tmp[num_statevars+compset.phase_record.phase_dof+1:
                  num_statevars+compset.phase_record.phase_dof+1+chempots.shape[0]] = chempots
            constraint_hess_tmp_view = <double[:compset.phase_record.num_dpot_cons,
                                               :num_statevars+1+compset.phase_record.phase_dof+chempots.shape[0],
                                               :num_statevars+1+compset.phase_record.phase_dof+chempots.shape[0]]>&constraint_hess_tmp[0]
            compset.phase_record.dpot_cons_hessian(constraint_hess_tmp_view, x_tmp)
            for cons_idx in range(compset.phase_record.num_dpot_cons):
                for idx_row in range(num_statevars):
                    for idx_col in range(idx_row, num_statevars):
                        hess[idx_row, idx_col] += lmul[constraint_offset + cons_idx] * \
                                                  constraint_hess_tmp_view[cons_idx, idx_row, idx_col]
                        if idx_row != idx_col:
                            hess[idx_col, idx_row] += lmul[constraint_offset + cons_idx] * \
                                                    constraint_hess_tmp_view[cons_idx, idx_col, idx_row]
                    for idx_col in range(compset.phase_record.phase_dof):
                        hess[idx_row, var_idx + idx_col] += lmul[constraint_offset + cons_idx] * \
                                                    constraint_hess_tmp_view[cons_idx, idx_row, num_statevars+idx_col]
                        hess[var_idx + idx_col, idx_row] += lmul[constraint_offset + cons_idx] * \
                                                    constraint_hess_tmp_view[cons_idx, num_statevars+idx_col, idx_row]
                    for idx_col in range(chempots.shape[0]):
                        hess[hess.shape[0]-chempots.shape[0]+idx_col, idx_row] += lmul[constraint_offset + cons_idx] * \
                                                  constraint_hess_tmp_view[cons_idx,
                                                                           constraint_hess_tmp_view.shape[2]-chempots.shape[0]+idx_col,
                                                                           idx_row]
                        hess[idx_row, hess.shape[0]-chempots.shape[0]+idx_col] += lmul[constraint_offset + cons_idx] * \
                                                  constraint_hess_tmp_view[cons_idx,
                                                                           idx_row,
                                                                           constraint_hess_tmp_view.shape[2]-chempots.shape[0]+idx_col]
                for idx_row in range(compset.phase_record.phase_dof):
                    for idx_col in range(idx_row, compset.phase_record.phase_dof):
                        hess[var_idx + idx_row, var_idx + idx_col] += lmul[constraint_offset + cons_idx] * \
                                                  constraint_hess_tmp_view[cons_idx, num_statevars+idx_row, num_statevars+idx_col]
                        if idx_row != idx_col:
                            hess[var_idx + idx_col, var_idx + idx_row] += lmul[constraint_offset + cons_idx] * \
                                                  constraint_hess_tmp_view[cons_idx, num_statevars+idx_col, num_statevars+idx_row]
                    for idx_col in range(chempots.shape[0]):
                        hess[hess.shape[0]-chempots.shape[0]+idx_col, var_idx+idx_row] += lmul[constraint_offset + cons_idx] * \
                                                  constraint_hess_tmp_view[cons_idx,
                                                                           constraint_hess_tmp_view.shape[2]-chempots.shape[0]+idx_col,
                                                                           num_statevars+idx_row]
                        hess[var_idx+idx_row, hess.shape[0]-chempots.shape[0]+idx_col] += lmul[constraint_offset + cons_idx] * \
                                                  constraint_hess_tmp_view[cons_idx,
                                                                           num_statevars+idx_row,
                                                                           constraint_hess_tmp_view.shape[2]-chempots.shape[0]+idx_col]
                for idx_row in range(chempots.shape[0]):
                    for idx_col in range(idx_row, chempots.shape[0]):
                        hess[hess.shape[0]-chempots.shape[0]+idx_col, hess.shape[0]-chempots.shape[0]+idx_row] += lmul[constraint_offset + cons_idx] * \
                                                  constraint_hess_tmp_view[cons_idx,
                                                                           constraint_hess_tmp_view.shape[2]-chempots.shape[0]+idx_col,
                                                                           constraint_hess_tmp_view.shape[2]-chempots.shape[0]+idx_row]
                        if idx_row != idx_col:
                            hess[hess.shape[0]-chempots.shape[0]+idx_row, hess.shape[0]-chempots.shape[0]+idx_col] += lmul[constraint_offset + cons_idx] * \
                                                      constraint_hess_tmp_view[cons_idx,
                                                                               constraint_hess_tmp_view.shape[2]-chempots.shape[0]+idx_row,
                                                                               constraint_hess_tmp_view.shape[2]-chempots.shape[0]+idx_col]
                # wrt phase amount
                for idx_row in range(num_statevars):
                    hess[idx_row, spidx] += lmul[constraint_offset + cons_idx] * constraint_hess_tmp_view[cons_idx, idx_row, constraint_hess_tmp_view.shape[2]-chempots.shape[0]-1]
                    hess[spidx, idx_row] += lmul[constraint_offset + cons_idx] * constraint_hess_tmp_view[cons_idx, constraint_hess_tmp_view.shape[2]-chempots.shape[0]-1, idx_row]
                for idx_row in range(compset.phase_record.phase_dof):
                    hess[var_idx + idx_row, spidx] += lmul[constraint_offset + cons_idx] * constraint_hess_tmp_view[cons_idx, num_statevars + idx_row, constraint_hess_tmp_view.shape[2]-chempots.shape[0]-1]
                    hess[spidx, var_idx + idx_row] += lmul[constraint_offset + cons_idx] * constraint_hess_tmp_view[cons_idx, constraint_hess_tmp_view.shape[2]-chempots.shape[0]-1, num_statevars + idx_row]
                for idx_row in range(chempots.shape[0]):
                    hess[hess.shape[0]-chempots.shape[0]+idx_row, spidx] += lmul[constraint_offset + cons_idx] * constraint_hess_tmp_view[cons_idx, constraint_hess_tmp_view.shape[2]-chempots.shape[0]+idx_row, constraint_hess_tmp_view.shape[2]-chempots.shape[0]-1]
                    hess[spidx, hess.shape[0]-chempots.shape[0]+idx_row] += lmul[constraint_offset + cons_idx] * constraint_hess_tmp_view[cons_idx, constraint_hess_tmp_view.shape[2]-chempots.shape[0]-1, constraint_hess_tmp_view.shape[2]-chempots.shape[0]+idx_row]
            x_tmp[num_statevars:] = 0
            constraint_hess_tmp[:] = 0
            var_idx += compset.phase_record.phase_dof
            constraint_offset += compset.phase_record.num_dpot_cons

        var_idx = num_statevars
        # Fourth: Multiphase constraints
        for phase_idx in range(self.num_phases):
            compset = self.composition_sets[phase_idx]
            spidx = self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx
            x_tmp[num_statevars:num_statevars+compset.phase_record.phase_dof] = \
                x[var_idx:var_idx+compset.phase_record.phase_dof]
            x_tmp[num_statevars+compset.phase_record.phase_dof] = x[spidx]
            constraint_hess_tmp_view = <double[:compset.phase_record.num_multiphase_cons,
                                               :num_statevars+1+compset.phase_record.phase_dof,
                                               :num_statevars+1+compset.phase_record.phase_dof]>&constraint_hess_tmp[0]
            compset.phase_record.multiphase_cons_hessian(constraint_hess_tmp_view, x_tmp)
            for cons_idx in range(compset.phase_record.num_multiphase_cons):
                for idx_row in range(num_statevars):
                    for idx_col in range(idx_row, num_statevars):
                        hess[idx_row, idx_col] += lmul[constraint_offset + cons_idx] * \
                                                  constraint_hess_tmp_view[cons_idx, idx_row, idx_col]
                        if idx_row != idx_col:
                            hess[idx_col, idx_row] += lmul[constraint_offset + cons_idx] * \
                                                    constraint_hess_tmp_view[cons_idx, idx_col, idx_row]
                    for idx_col in range(compset.phase_record.phase_dof):
                        hess[idx_row, var_idx + idx_col] += lmul[constraint_offset + cons_idx] * \
                                                    constraint_hess_tmp_view[cons_idx, idx_row, num_statevars+idx_col]
                        hess[var_idx + idx_col, idx_row] += lmul[constraint_offset + cons_idx] * \
                                                    constraint_hess_tmp_view[cons_idx, num_statevars+idx_col, idx_row]

                for idx_row in range(compset.phase_record.phase_dof):
                    for idx_col in range(idx_row, compset.phase_record.phase_dof):
                        hess[var_idx + idx_row, var_idx + idx_col] += lmul[constraint_offset + cons_idx] * \
                                                  constraint_hess_tmp_view[cons_idx, num_statevars+idx_row, num_statevars+idx_col]
                        if idx_row != idx_col:
                            hess[var_idx + idx_col, var_idx + idx_row] += lmul[constraint_offset + cons_idx] * \
                                                  constraint_hess_tmp_view[cons_idx, num_statevars+idx_col, num_statevars+idx_row]

                # wrt phase amount
                for idx_row in range(num_statevars):
                    hess[idx_row, spidx] += lmul[constraint_offset + cons_idx] * constraint_hess_tmp_view[cons_idx, idx_row, constraint_hess_tmp_view.shape[2]-1]
                    hess[spidx, idx_row] += lmul[constraint_offset + cons_idx] * constraint_hess_tmp_view[cons_idx, constraint_hess_tmp_view.shape[2]-1, idx_row]
                for idx_row in range(compset.phase_record.phase_dof):
                    hess[var_idx + idx_row, spidx] += lmul[constraint_offset + cons_idx] * constraint_hess_tmp_view[cons_idx, num_statevars + idx_row, constraint_hess_tmp_view.shape[2]-1]
                    hess[spidx, var_idx + idx_row] += lmul[constraint_offset + cons_idx] * constraint_hess_tmp_view[cons_idx, constraint_hess_tmp_view.shape[2]-1, num_statevars + idx_row]
            x_tmp[num_statevars:] = 0
            constraint_hess_tmp[:] = 0
            var_idx += compset.phase_record.phase_dof
        constraint_offset += compset.phase_record.num_multiphase_cons

        # Fifth: Gibbs-Duhem relations
        var_idx = num_statevars
        for phase_idx in range(self.num_phases):
            compset = self.composition_sets[phase_idx]
            spidx = self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx
            phase_amt = x_in[spidx]
            x = np.r_[x_in[:len(compset.phase_record.state_variables)], x_in[var_idx:var_idx+compset.phase_record.phase_dof]]
            x_tmp_2d_view = <double[:1,:num_statevars+compset.phase_record.phase_dof]>&x[0]
            hess_tmp_view = <double[:num_statevars+compset.phase_record.phase_dof,:num_statevars+compset.phase_record.phase_dof]>&hess_tmp[0]
            dof_2d_view = <double[:1,:x.shape[0]]>&x[0]
            compset.phase_record.obj(energy_out, dof_2d_view)
            compset.phase_record.grad(energy_gradient, x)
            compset.phase_record.hess(hess_tmp_view, x)
            for comp_idx in range(moles.shape[0]):
                out_phase_mass = <double[:1]>&moles[comp_idx]
                moles_gradient_view = <double[:num_statevars+compset.phase_record.phase_dof]>&moles_gradient[comp_idx, 0]
                moles_hessian_view = <double[:num_statevars+compset.phase_record.phase_dof,
                                             :num_statevars+compset.phase_record.phase_dof]>&moles_hessian_tmp[0]
                compset.phase_record.mass_obj(out_phase_mass, x_tmp_2d_view, comp_idx)
                compset.phase_record.mass_grad(moles_gradient_view, x, comp_idx)
                compset.phase_record.mass_hess(moles_hessian_view, x, comp_idx)
                moles_hessian[comp_idx,
                              :num_statevars+compset.phase_record.phase_dof,
                              :num_statevars+compset.phase_record.phase_dof] = moles_hessian_view
                moles_hessian_tmp[:] = 0
            # wrt statevars, statevars
            for sv_idx in range(num_statevars):
                for dof_idx in range(sv_idx, num_statevars):
                    if sv_idx != dof_idx:
                        hess[dof_idx, sv_idx] += lmul[constraint_offset] * phase_amt * hess_tmp_view[dof_idx, sv_idx]
                    hess[sv_idx, dof_idx] += lmul[constraint_offset] * phase_amt * hess_tmp_view[sv_idx, dof_idx]
                    for comp_idx in range(chempots.shape[0]):
                        if sv_idx != dof_idx:
                            hess[dof_idx, sv_idx] += -lmul[constraint_offset] * phase_amt * chempots[comp_idx] * moles_hessian[comp_idx, dof_idx, sv_idx]
                        hess[sv_idx, dof_idx] += -lmul[constraint_offset] * phase_amt * chempots[comp_idx] * moles_hessian[comp_idx, sv_idx, dof_idx]
            # wrt statevars, phase_dof
            for sv_idx in range(num_statevars):
                for dof_idx in range(compset.phase_record.phase_dof):
                    hess[var_idx+dof_idx, sv_idx] += lmul[constraint_offset] * phase_amt * hess_tmp_view[num_statevars+dof_idx, sv_idx]
                    hess[sv_idx, var_idx+dof_idx] += lmul[constraint_offset] * phase_amt * hess_tmp_view[sv_idx, num_statevars+dof_idx]
                    for comp_idx in range(chempots.shape[0]):
                        hess[var_idx+dof_idx, sv_idx] += -lmul[constraint_offset] * phase_amt * chempots[comp_idx] * moles_hessian[comp_idx, num_statevars+dof_idx, sv_idx]
                        hess[sv_idx, var_idx+dof_idx] += -lmul[constraint_offset] * phase_amt * chempots[comp_idx] * moles_hessian[comp_idx, sv_idx, num_statevars+dof_idx]
            # wrt statevars, phase amount
            for sv_idx in range(num_statevars):
                hess[spidx, sv_idx] += lmul[constraint_offset] * energy_gradient[sv_idx]
                hess[sv_idx, spidx] += lmul[constraint_offset] * energy_gradient[sv_idx]
                for comp_idx in range(chempots.shape[0]):
                    hess[spidx, sv_idx] += -lmul[constraint_offset] * chempots[comp_idx] * moles_gradient[comp_idx, sv_idx]
                    hess[sv_idx, spidx] += -lmul[constraint_offset] * chempots[comp_idx] * moles_gradient[comp_idx, sv_idx]
            # wrt statevars, chemical potentials
            for sv_idx in range(num_statevars):
                for comp_idx in range(chempots.shape[0]):
                    hess[chempot_idx+comp_idx, sv_idx] -= lmul[constraint_offset] * phase_amt * moles_gradient[comp_idx, sv_idx]
                    hess[sv_idx, chempot_idx+comp_idx] -= lmul[constraint_offset] * phase_amt * moles_gradient[comp_idx, sv_idx]
            # wrt phase_dof, phase_dof
            for dof_idx in range(compset.phase_record.phase_dof):
                for grad_idx in range(dof_idx, compset.phase_record.phase_dof):
                    if dof_idx != grad_idx:
                        hess[var_idx+dof_idx, var_idx+grad_idx] += lmul[constraint_offset] * phase_amt * hess_tmp_view[num_statevars+dof_idx, num_statevars+grad_idx]
                    hess[var_idx+grad_idx, var_idx+dof_idx] += lmul[constraint_offset] * phase_amt * hess_tmp_view[num_statevars+grad_idx, num_statevars+dof_idx]
                    for comp_idx in range(chempots.shape[0]):
                        if dof_idx != grad_idx:
                            hess[var_idx+dof_idx, var_idx+grad_idx] += -lmul[constraint_offset] * phase_amt * chempots[comp_idx] * moles_hessian[comp_idx, num_statevars+dof_idx, num_statevars+grad_idx]
                        hess[var_idx+grad_idx, var_idx+dof_idx] += -lmul[constraint_offset] * phase_amt * chempots[comp_idx] * moles_hessian[comp_idx, num_statevars+grad_idx, num_statevars+dof_idx]
            # wrt phase_dof, phase amount
            for dof_idx in range(compset.phase_record.phase_dof):
                hess[var_idx+dof_idx, spidx] += lmul[constraint_offset] * energy_gradient[num_statevars+dof_idx]
                hess[spidx, var_idx+dof_idx] += lmul[constraint_offset] * energy_gradient[num_statevars+dof_idx]
                for comp_idx in range(chempots.shape[0]):
                    hess[var_idx+dof_idx, spidx] += -lmul[constraint_offset] * chempots[comp_idx] * moles_gradient[comp_idx, num_statevars+dof_idx]
                    hess[spidx, var_idx+dof_idx] += -lmul[constraint_offset] * chempots[comp_idx] * moles_gradient[comp_idx, num_statevars+dof_idx]
            # wrt phase_dof, chemical potentials
            for dof_idx in range(compset.phase_record.phase_dof):
                for comp_idx in range(chempots.shape[0]):
                    hess[var_idx+dof_idx, chempot_idx+comp_idx] += -lmul[constraint_offset] * phase_amt * moles_gradient[comp_idx, num_statevars+dof_idx]
                    hess[chempot_idx+comp_idx, var_idx+dof_idx] += -lmul[constraint_offset] * phase_amt * moles_gradient[comp_idx, num_statevars+dof_idx]
            # wrt phase amount, phase amount (=zero)
            # wrt phase amount, chemical potentials
            for comp_idx in range(chempots.shape[0]):
                hess[spidx, chempot_idx+comp_idx] += -lmul[constraint_offset] * moles[comp_idx]
                hess[chempot_idx+comp_idx, spidx] += -lmul[constraint_offset] * moles[comp_idx]
            # wrt chemical potentials, chemical potentials (=zero)
            hess_tmp[:] = 0
            energy_out[0] = 0
            energy_gradient[:] = 0
            moles[:] = 0
            moles_gradient[:,:] = 0
            moles_hessian_tmp[:] = 0
            moles_hessian[:,:,:] = 0
            var_idx += compset.phase_record.phase_dof
            constraint_offset += 1
        result = np.array(hess)[np.tril_indices(hess.shape[0])]
        return result

    def hessianstructure(self):
        return np.tril_indices(self.num_vars)

    def mass_gradient(self, x_in, selected_phase_idx=None):
        cdef CompositionSet compset = self.composition_sets[0]
        cdef int num_statevars = len(compset.phase_record.state_variables)
        cdef double[:, :,::1] mass_gradient_matrix = np.zeros((self.num_phases, len(self.nonvacant_elements), self.num_vars))
        cdef double phase_amt = 0
        cdef int phase_idx, comp_idx, dof_idx, spidx
        cdef double[::1] x = np.array(x_in)
        cdef double[::1] x_tmp, out_phase_mass
        cdef double[:,::1] x_tmp_2d_view
        cdef double[::1] out_tmp = np.zeros(self.num_vars)
        var_idx = num_statevars
        for phase_idx in range(mass_gradient_matrix.shape[0]):
            if (selected_phase_idx is not None) and (selected_phase_idx != phase_idx):
                var_idx += compset.phase_record.phase_dof
                continue
            compset = self.composition_sets[phase_idx]
            spidx = self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx
            if selected_phase_idx is None:
                phase_amt = x[spidx]
            else:
                phase_amt = 1.0
            x_tmp = np.r_[x[:num_statevars], x[var_idx:var_idx+compset.phase_record.phase_dof]]
            x_tmp_2d_view = <double[:1,:num_statevars+compset.phase_record.phase_dof]>&x_tmp[0]
            for comp_idx in range(mass_gradient_matrix.shape[1]):
                compset.phase_record.mass_grad(out_tmp, x_tmp, comp_idx)
                mass_gradient_matrix[phase_idx, comp_idx, var_idx:var_idx+compset.phase_record.phase_dof] = out_tmp[num_statevars:num_statevars+compset.phase_record.phase_dof]
                mass_gradient_matrix[phase_idx, comp_idx, :num_statevars] = out_tmp[:num_statevars]
                out_phase_mass = <double[:1]>&mass_gradient_matrix[phase_idx, comp_idx, spidx]
                compset.phase_record.mass_obj(out_phase_mass, x_tmp_2d_view, comp_idx)
                mass_gradient_matrix[phase_idx, comp_idx, spidx] = out_phase_mass[0]
                out_tmp[:] = 0
                for dof_idx in range(compset.phase_record.phase_dof):
                    mass_gradient_matrix[phase_idx, comp_idx, var_idx + dof_idx] *= phase_amt
            var_idx += compset.phase_record.phase_dof
        return np.array(mass_gradient_matrix).sum(axis=0).T

    def mass_jacobian(self, x_in, selected_phase_idx=None):
        """For chemical potential calculation."""
        cdef CompositionSet compset = self.composition_sets[0]
        cdef int num_statevars = len(compset.phase_record.state_variables)
        # Exclude chemical potentials from equality check
        cdef np.ndarray active_ineq = np.flatnonzero((np.array(x_in[-len(self.nonvacant_elements):]) <= 1.1*MIN_SITE_FRACTION))
        cdef size_t num_active_ineq = len(active_ineq)
        cdef double[:, ::1] mass_jac = np.zeros((self.num_internal_constraints + num_active_ineq + len(self.nonvacant_elements), self.num_vars))
        cdef double[:, ::1] mass_jac_tmp = np.zeros((self.num_internal_constraints + len(self.nonvacant_elements), self.num_vars))
        cdef double[:, ::1] mass_jac_tmp_view, mass_grad
        cdef double[::1] x = np.array(x_in)
        cdef double[::1] x_tmp
        cdef int var_idx = 0
        cdef int phase_idx, grad_idx
        cdef int constraint_offset = 0
        # First: Phase internal constraints
        var_idx = num_statevars
        for phase_idx in range(self.num_phases):
            compset = self.composition_sets[phase_idx]
            x_tmp = np.r_[x[:num_statevars], x[var_idx:var_idx+compset.phase_record.phase_dof]]
            mass_jac_tmp_view = <double[:compset.phase_record.num_internal_cons,
                                              :num_statevars+compset.phase_record.phase_dof]>&mass_jac_tmp[0,0]
            compset.phase_record.internal_jacobian(mass_jac_tmp_view, x_tmp)
            mass_jac[constraint_offset:constraint_offset + compset.phase_record.num_internal_cons,
                               var_idx:var_idx+compset.phase_record.phase_dof] = \
                mass_jac_tmp_view[:compset.phase_record.num_internal_cons, num_statevars:num_statevars+compset.phase_record.phase_dof]
            for iter_idx in range(num_statevars):
                for idx in range(compset.phase_record.num_internal_cons):
                    mass_jac[constraint_offset + idx, iter_idx] += \
                        mass_jac_tmp_view[idx, iter_idx]
            mass_jac_tmp[:,:] = 0
            var_idx += compset.phase_record.phase_dof
            constraint_offset += compset.phase_record.num_internal_cons
        # Second: Active inequality constraints
        for idx in range(num_active_ineq):
            mass_jac[constraint_offset, active_ineq[idx]] = 1
            constraint_offset += 1
        # Third: Mass constraints for pure elements
        mass_grad = self.mass_gradient(x_in, selected_phase_idx=selected_phase_idx).T
        var_idx = 0
        for grad_idx in range(constraint_offset, mass_jac.shape[0]):
            for var_idx in range(self.num_vars):
                mass_jac[grad_idx, var_idx] = mass_grad[grad_idx - constraint_offset, var_idx]
        return np.array(mass_jac)

    def chemical_potentials(self, x_in):
        "Assuming the input is a feasible solution."
        # mu = (A+) grad
        jac_pinv = np.linalg.pinv(self.mass_jacobian(x_in).T)
        mu = np.dot(jac_pinv, self.energy_gradient(x_in))[-len(self.nonvacant_elements):]
        return mu

    def chemical_potential_gradient(self, x_in, selected_phase_idx=None):
        "Assuming the input is a feasible solution."
        # mu' = (A+)' grad + (A+) hess
        jac = self.mass_jacobian(x_in, selected_phase_idx=selected_phase_idx).T
        jac_pinv = np.linalg.pinv(jac)
        # Axes swap needed for compatibility with _pinv_derivative
        mass_hess = np.swapaxes(self.mass_cons_hessian(x_in, selected_phase_idx=selected_phase_idx), 0, 1)
        hess = self.obj_hessian(x_in, selected_phase_idx=selected_phase_idx)
        grad = self.gradient(x_in, selected_phase_idx=selected_phase_idx)
        jac_pinv_prime = _pinv_derivative(jac, jac_pinv, mass_hess)
        mu_prime = np.dot(jac_pinv, hess) + np.einsum('ijk,j->ik', jac_pinv_prime, grad)
        return mu_prime[-len(self.nonvacant_elements):]

    def mass_cons_hessian(self, x_in, selected_phase_idx=None):
        cdef CompositionSet compset = self.composition_sets[0]
        cdef size_t num_statevars = len(compset.phase_record.state_variables)
        cdef np.ndarray active_ineq = np.flatnonzero((np.array(x_in) <= 1.1*MIN_SITE_FRACTION))
        cdef size_t num_active_ineq = len(active_ineq)
        cdef double[:, :, ::1] mass_cons_hess = np.zeros((self.num_internal_constraints + num_active_ineq + len(self.nonvacant_elements),
                                                          self.num_vars, self.num_vars))
        cdef double[::1] mass_cons_hess_tmp = np.zeros((self.num_internal_constraints + len(self.nonvacant_elements) *
                                                        self.num_vars) * self.num_vars)
        cdef double[::1] mass_grad_tmp = np.zeros(self.num_vars)
        cdef double[:, :, ::1] mass_cons_hess_tmp_view
        cdef double[:, ::1] mass_hess_tmp_view
        cdef double[::1] x = np.array(x_in)
        cdef double[::1] x_tmp = np.zeros(x.shape[0])
        cdef double phase_frac = 0
        cdef size_t var_idx = 0
        cdef size_t phase_idx, grad_idx, cons_idx, dof_idx, sv_idx
        cdef size_t row, col
        cdef size_t constraint_offset = 0
        x_tmp[:num_statevars] = x[:num_statevars]
        # First: Phase internal constraints
        var_idx = num_statevars
        for phase_idx in range(self.num_phases):
            compset = self.composition_sets[phase_idx]
            x_tmp[num_statevars:num_statevars+compset.phase_record.phase_dof] = \
                x[var_idx:var_idx+compset.phase_record.phase_dof]
            mass_cons_hess_tmp_view = <double[:compset.phase_record.num_internal_cons,
                                              :num_statevars+compset.phase_record.phase_dof,
                                              :num_statevars+compset.phase_record.phase_dof]>&mass_cons_hess_tmp[0]
            compset.phase_record.internal_cons_hessian(mass_cons_hess_tmp_view, x_tmp)
            mass_cons_hess[constraint_offset:constraint_offset + compset.phase_record.num_internal_cons,
                           var_idx:var_idx+compset.phase_record.phase_dof,
                           var_idx:var_idx+compset.phase_record.phase_dof] = \
                mass_cons_hess_tmp_view[:compset.phase_record.num_internal_cons,
                                        num_statevars:num_statevars+compset.phase_record.phase_dof,
                                        num_statevars:num_statevars+compset.phase_record.phase_dof]
            for iter_idx in range(num_statevars):
                for cons_idx in range(compset.phase_record.num_internal_cons):
                    for dof_idx in range(compset.phase_record.phase_dof):
                        mass_cons_hess[constraint_offset + cons_idx, iter_idx, var_idx + dof_idx] += \
                            mass_cons_hess_tmp_view[cons_idx, iter_idx, num_statevars + dof_idx]
                        mass_cons_hess[constraint_offset + cons_idx, var_idx + dof_idx, iter_idx] += \
                            mass_cons_hess_tmp_view[cons_idx, iter_idx, num_statevars + dof_idx]
                    for sv_idx in range(num_statevars):
                        mass_cons_hess[constraint_offset + cons_idx, iter_idx, sv_idx] += \
                            mass_cons_hess_tmp_view[cons_idx, iter_idx, sv_idx]
                        if iter_idx != sv_idx:
                            mass_cons_hess[constraint_offset + cons_idx, sv_idx, iter_idx] += \
                                mass_cons_hess_tmp_view[cons_idx, iter_idx, sv_idx]
            mass_cons_hess_tmp[:] = 0
            x_tmp[num_statevars:] = 0
            var_idx += compset.phase_record.phase_dof
            constraint_offset += compset.phase_record.num_internal_cons
        # Second: Active inequality constraints (Linear)
        constraint_offset += num_active_ineq
        # Third: Mass constraints for pure elements
        var_idx = num_statevars
        for phase_idx in range(self.num_phases):
            if (selected_phase_idx is not None) and (selected_phase_idx != phase_idx):
                x_tmp[num_statevars:] = 0
                var_idx += compset.phase_record.phase_dof
                continue
            compset = self.composition_sets[phase_idx]
            x_tmp[num_statevars:num_statevars+compset.phase_record.phase_dof] = \
                x[var_idx:var_idx+compset.phase_record.phase_dof]
            if selected_phase_idx is None:
                phase_frac = x[self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx]
            else:
                phase_frac = 1.0
            mass_hess_tmp_view = <double[:num_statevars+compset.phase_record.phase_dof,
                                         :num_statevars+compset.phase_record.phase_dof]>&mass_cons_hess_tmp[0]
            for cons_idx in range(len(self.nonvacant_elements)):
                compset.phase_record.mass_grad(mass_grad_tmp, x_tmp, cons_idx)
                compset.phase_record.mass_hess(mass_hess_tmp_view, x_tmp, cons_idx)
                for col in range(compset.phase_record.phase_dof):
                    for row in range(col, compset.phase_record.phase_dof):
                        mass_cons_hess[constraint_offset+cons_idx, var_idx+row, var_idx+col] += \
                            phase_frac * mass_hess_tmp_view[num_statevars+row, num_statevars+col]
                        if col != row:
                            mass_cons_hess[constraint_offset+cons_idx, var_idx+col, var_idx+row] += \
                                phase_frac * mass_hess_tmp_view[num_statevars+row, num_statevars+col]
                for iter_idx in range(num_statevars):
                    for dof_idx in range(compset.phase_record.phase_dof):
                        mass_cons_hess[constraint_offset + cons_idx, iter_idx, var_idx + dof_idx] += \
                            phase_frac * mass_hess_tmp_view[iter_idx, dof_idx]
                        mass_cons_hess[constraint_offset + cons_idx, var_idx + dof_idx, iter_idx] += \
                            phase_frac * mass_hess_tmp_view[iter_idx, dof_idx]
                    for sv_idx in range(num_statevars):
                        mass_cons_hess[constraint_offset + cons_idx, iter_idx, sv_idx] += \
                            phase_frac * mass_hess_tmp_view[iter_idx, sv_idx]
                        if iter_idx != sv_idx:
                            mass_cons_hess[constraint_offset + cons_idx, sv_idx, iter_idx] += \
                                phase_frac * mass_hess_tmp_view[iter_idx, sv_idx]
                # wrt phase_frac
                for dof_idx in range(num_statevars+compset.phase_record.phase_dof):
                    mass_cons_hess[constraint_offset + cons_idx,
                                   self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx, dof_idx] = mass_grad_tmp[dof_idx]
                    mass_cons_hess[constraint_offset + cons_idx,
                                   dof_idx, self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx] = mass_grad_tmp[dof_idx]
                mass_cons_hess_tmp[:] = 0
                mass_grad_tmp[:] = 0
            x_tmp[num_statevars:] = 0
            var_idx += compset.phase_record.phase_dof
        return np.array(mass_cons_hess)

    def constraints(self, x_in):
        cdef CompositionSet compset = self.composition_sets[0]
        cdef int num_statevars = len(compset.phase_record.state_variables)
        cdef double[::1] x = np.array(x_in)
        cdef double tmp = 0
        cdef double mass_tmp = 0
        cdef double[:,::1] dof_2d_view = <double[:1,:x.shape[0]]>&x[0]
        cdef double[::1] energy_2d_view = <double[:1]>&tmp
        cdef double[::1] l_constraints = np.zeros(self.num_constraints)
        cdef double[::1] l_constraints_tmp = np.zeros(self.num_constraints)
        cdef double[::1] chempots = np.zeros(len(self.nonvacant_elements))
        cdef double[::1] moles = np.zeros(len(self.nonvacant_elements))
        cdef int phase_idx, var_offset, constraint_offset, var_idx, idx, spidx
        cdef double[::1] x_tmp = np.zeros(x.shape[0])
        cdef double phase_amt
        chempots[:] = x[-len(self.nonvacant_elements):]
        x_tmp[:num_statevars] = x[:num_statevars]

        # First: Fixed degree of freedom constraints
        constraint_offset = 0
        for idx in range(self.num_fixed_dof_constraints):
            l_constraints[idx] = x[self.fixed_dof_indices[idx]]
            constraint_offset += 1
        # Second: Phase internal constraints
        var_idx = num_statevars
        for phase_idx in range(self.num_phases):
            compset = self.composition_sets[phase_idx]
            x_tmp[num_statevars:num_statevars+compset.phase_record.phase_dof] = \
                x[var_idx:var_idx+compset.phase_record.phase_dof]
            compset.phase_record.internal_constraints(
                l_constraints[constraint_offset:constraint_offset + compset.phase_record.num_internal_cons],
                x_tmp
            )
            x_tmp[num_statevars:] = 0
            var_idx += compset.phase_record.phase_dof
            constraint_offset += compset.phase_record.num_internal_cons

        # Third: Diffusion potential constraints
        var_offset = num_statevars
        for phase_idx in range(self.num_phases):
            compset = self.composition_sets[phase_idx]
            spidx = self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx
            x_tmp[num_statevars:num_statevars+compset.phase_record.phase_dof] = \
                x[var_offset:var_offset+compset.phase_record.phase_dof]
            x_tmp[num_statevars+compset.phase_record.phase_dof] = x[spidx]
            compset.phase_record.dpot_constraints(l_constraints_tmp, x_tmp)
            for c_idx in range(compset.phase_record.num_dpot_cons):
                l_constraints[constraint_offset + c_idx] += l_constraints_tmp[c_idx]
            x_tmp[num_statevars:] = 0
            l_constraints_tmp[:] = 0
            var_offset += compset.phase_record.phase_dof
            constraint_offset += compset.phase_record.num_dpot_cons

        # Fourth: Multiphase constraints
        var_offset = num_statevars
        for phase_idx in range(self.num_phases):
            compset = self.composition_sets[phase_idx]
            spidx = self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx
            x_tmp[num_statevars:num_statevars+compset.phase_record.phase_dof] = \
                x[var_offset:var_offset+compset.phase_record.phase_dof]
            x_tmp[num_statevars+compset.phase_record.phase_dof] = x[spidx]
            compset.phase_record.multiphase_constraints(l_constraints_tmp, x_tmp)
            for c_idx in range(compset.phase_record.num_multiphase_cons):
                l_constraints[constraint_offset + c_idx] += l_constraints_tmp[c_idx]
            x_tmp[num_statevars:] = 0
            l_constraints_tmp[:] = 0
            var_offset += compset.phase_record.phase_dof
        constraint_offset += compset.phase_record.num_multiphase_cons

        # Fifth: Gibbs-Duhem relations
        var_offset = num_statevars
        for phase_idx in range(self.num_phases):
            compset = self.composition_sets[phase_idx]
            spidx = self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx
            phase_amt = x_in[spidx]
            x = np.r_[x_in[:len(compset.phase_record.state_variables)], x_in[var_offset:var_offset+compset.phase_record.phase_dof]]
            x_tmp_2d_view = <double[:1,:num_statevars+compset.phase_record.phase_dof]>&x[0]
            for comp_idx in range(moles.shape[0]):
                out_phase_mass = <double[:1]>&moles[comp_idx]
                compset.phase_record.mass_obj(out_phase_mass, x_tmp_2d_view, comp_idx)
            dof_2d_view = <double[:1,:x.shape[0]]>&x[0]
            compset.phase_record.obj(energy_2d_view, dof_2d_view)
            l_constraints[constraint_offset] = phase_amt * (tmp - np.dot(chempots, moles))
            tmp = 0
            energy_2d_view = <double[:1]>&tmp
            moles[:] = 0
            constraint_offset += 1
            var_offset += compset.phase_record.phase_dof
        print('l_constraints', np.array(l_constraints))
        return np.array(l_constraints)

    def jacobian(self, x_in):
        cdef CompositionSet compset = self.composition_sets[0]
        cdef int num_statevars = len(compset.phase_record.state_variables)
        cdef double[::1] x = np.array(x_in)
        cdef double[::1] x_tmp = np.zeros(x.shape[0])
        cdef double[:,::1] constraint_jac = np.zeros((self.num_constraints, self.num_vars))
        cdef double[:,::1] constraint_jac_tmp = np.zeros((self.num_constraints, self.num_vars))
        cdef double[:,::1] constraint_jac_tmp_view
        cdef double[::1] chempots = np.zeros(len(self.nonvacant_elements))
        cdef double[::1] moles = np.zeros(len(self.nonvacant_elements))
        cdef double[:, ::1] moles_gradient = np.zeros((len(self.nonvacant_elements), self.num_vars))
        cdef double[::1] moles_gradient_view
        cdef double[::1] energy_out = np.atleast_1d(np.zeros(1,  dtype=np.float64))
        cdef double[:, ::1] dof_2d_view
        cdef double[::1] energy_gradient = np.zeros(self.num_vars)
        cdef double phase_amt
        cdef int phase_idx, var_offset, constraint_offset, var_idx, iter_idx, grad_idx, \
            hess_idx, comp_idx, idx, sum_idx, spidx, active_in_subl, phase_offset

        chempots[:] = x[-len(self.nonvacant_elements):]
        x_tmp[:num_statevars] = x[:num_statevars]

        # First: Fixed degree of freedom constraints
        constraint_offset = 0
        for idx in range(self.num_fixed_dof_constraints):
            var_idx = self.fixed_dof_indices[idx]
            constraint_jac[idx, var_idx] = 1
            constraint_offset += 1

        # Second: Phase internal constraints
        var_idx = num_statevars
        for phase_idx in range(self.num_phases):
            compset = self.composition_sets[phase_idx]
            x_tmp[num_statevars:num_statevars+compset.phase_record.phase_dof] = \
                x[var_idx:var_idx+compset.phase_record.phase_dof]
            constraint_jac_tmp_view = <double[:compset.phase_record.num_internal_cons,
                                              :num_statevars+compset.phase_record.phase_dof]>&constraint_jac_tmp[0,0]
            compset.phase_record.internal_jacobian(constraint_jac_tmp_view, x_tmp)
            constraint_jac[constraint_offset:constraint_offset + compset.phase_record.num_internal_cons,
                               var_idx:var_idx+compset.phase_record.phase_dof] = \
                constraint_jac_tmp_view[:compset.phase_record.num_internal_cons, num_statevars:num_statevars+compset.phase_record.phase_dof]
            for iter_idx in range(num_statevars):
                for idx in range(compset.phase_record.num_internal_cons):
                    constraint_jac[constraint_offset + idx, iter_idx] += \
                        constraint_jac_tmp_view[idx, iter_idx]
            constraint_jac_tmp[:,:] = 0
            x_tmp[num_statevars:] = 0
            var_idx += compset.phase_record.phase_dof
            constraint_offset += compset.phase_record.num_internal_cons

        var_offset = num_statevars
        # Third: Diffusion potential constraints
        for phase_idx in range(self.num_phases):
            compset = self.composition_sets[phase_idx]
            spidx = self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx
            x_tmp[num_statevars:num_statevars+compset.phase_record.phase_dof] = \
                x[var_offset:var_offset+compset.phase_record.phase_dof]
            x_tmp[num_statevars+compset.phase_record.phase_dof] = x[spidx]
            x_tmp[num_statevars+compset.phase_record.phase_dof+1:
                  num_statevars+compset.phase_record.phase_dof+1+chempots.shape[0]] = chempots
            constraint_jac_tmp_view = <double[:compset.phase_record.num_dpot_cons,
                                              :num_statevars+1+compset.phase_record.phase_dof+chempots.shape[0]]>&constraint_jac_tmp[0,0]
            compset.phase_record.dpot_jacobian(constraint_jac_tmp_view, x_tmp)
            for idx in range(compset.phase_record.num_dpot_cons):
                for iter_idx in range(compset.phase_record.phase_dof):
                    constraint_jac[constraint_offset+idx, var_offset+iter_idx] = constraint_jac_tmp_view[idx, num_statevars+iter_idx]
                for iter_idx in range(num_statevars):
                    constraint_jac[constraint_offset+idx, iter_idx] += constraint_jac_tmp_view[idx, iter_idx]
                for iter_idx in range(chempots.shape[0]):
                    constraint_jac[constraint_offset+idx, constraint_jac.shape[1]-chempots.shape[0]+iter_idx] += constraint_jac_tmp_view[idx, constraint_jac_tmp_view.shape[1]-chempots.shape[0]+iter_idx]
                constraint_jac[constraint_offset+idx, spidx] = constraint_jac_tmp_view[idx, constraint_jac_tmp_view.shape[1]-chempots.shape[0]-1]
            x_tmp[num_statevars:] = 0
            constraint_jac_tmp[:,:] = 0
            var_offset += compset.phase_record.phase_dof
            constraint_offset += compset.phase_record.num_dpot_cons

        var_offset = num_statevars
        # Fourth: Multiphase constraints
        for phase_idx in range(self.num_phases):
            compset = self.composition_sets[phase_idx]
            spidx = self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx
            x_tmp[num_statevars:num_statevars+compset.phase_record.phase_dof] = \
                x[var_offset:var_offset+compset.phase_record.phase_dof]
            x_tmp[num_statevars+compset.phase_record.phase_dof] = x[spidx]
            constraint_jac_tmp_view = <double[:compset.phase_record.num_multiphase_cons,
                                              :num_statevars+1+compset.phase_record.phase_dof]>&constraint_jac_tmp[0,0]
            compset.phase_record.multiphase_jacobian(constraint_jac_tmp_view, x_tmp)
            for idx in range(compset.phase_record.num_multiphase_cons):
                for iter_idx in range(compset.phase_record.phase_dof):
                    constraint_jac[constraint_offset+idx, var_offset+iter_idx] = constraint_jac_tmp_view[idx, num_statevars+iter_idx]
                for iter_idx in range(num_statevars):
                    constraint_jac[constraint_offset+idx, iter_idx] += constraint_jac_tmp_view[idx, iter_idx]
                constraint_jac[constraint_offset+idx, spidx] = constraint_jac_tmp_view[idx, constraint_jac_tmp_view.shape[1]-1]
            x_tmp[num_statevars:] = 0
            constraint_jac_tmp[:,:] = 0
            var_offset += compset.phase_record.phase_dof
        constraint_offset += compset.phase_record.num_multiphase_cons

        # Fifth: Gibbs-Duhem relations
        var_offset = num_statevars
        chempots[:] = x[-len(self.nonvacant_elements):]
        for phase_idx in range(self.num_phases):
            compset = self.composition_sets[phase_idx]
            spidx = self.num_vars - len(self.nonvacant_elements) - self.num_phases + phase_idx
            phase_amt = x_in[spidx]
            x = np.r_[x_in[:len(compset.phase_record.state_variables)], x_in[var_offset:var_offset+compset.phase_record.phase_dof]]
            x_tmp_2d_view = <double[:1,:num_statevars+compset.phase_record.phase_dof]>&x[0]
            for comp_idx in range(moles.shape[0]):
                out_phase_mass = <double[:1]>&moles[comp_idx]
                moles_gradient_view = <double[:num_statevars+compset.phase_record.phase_dof]>&moles_gradient[comp_idx, 0]
                compset.phase_record.mass_obj(out_phase_mass, x_tmp_2d_view, comp_idx)
                compset.phase_record.mass_grad(moles_gradient_view, x, comp_idx)
            dof_2d_view = <double[:1,:x.shape[0]]>&x[0]
            compset.phase_record.obj(energy_out, dof_2d_view)
            compset.phase_record.grad(energy_gradient, x)
            # wrt statevars
            for iter_idx in range(num_statevars):
                constraint_jac[constraint_offset, iter_idx] = phase_amt * (energy_gradient[iter_idx] - np.dot(chempots, moles_gradient[:, iter_idx]))
            # wrt phase dof
            for iter_idx in range(compset.phase_record.phase_dof):
                constraint_jac[constraint_offset, var_offset + iter_idx] = phase_amt * (energy_gradient[num_statevars+iter_idx] - np.dot(chempots, moles_gradient[:, num_statevars+iter_idx]))
            # wrt phase amount
            constraint_jac[constraint_offset, spidx] = (energy_out - np.dot(chempots, moles))
            # wrt chemical potentials
            for iter_idx in range(chempots.shape[0]):
                constraint_jac[constraint_offset, self.num_vars - chempots.shape[0] + iter_idx] = -phase_amt * moles[iter_idx]
            moles[:] = 0
            moles_gradient[:,:] = 0
            energy_gradient[:] = 0
            energy_out[0] = 0
            constraint_offset += 1
            var_offset += compset.phase_record.phase_dof
        return np.array(constraint_jac)
