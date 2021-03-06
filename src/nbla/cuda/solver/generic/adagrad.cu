// Copyright (c) 2017 Sony Corporation. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <nbla/cuda/common.hpp>
#include <nbla/cuda/solver/adagrad.hpp>

#include "./weight_decay.cuh"

namespace nbla {

template <typename T>
__global__ void kernel_adagrad_update(const int num, T *data, const T *grad,
                                      T *g, const float lr, const float eps) {
  NBLA_CUDA_KERNEL_LOOP(idx, num) {
    g[idx] += grad[idx] * grad[idx];
    data[idx] -= lr * grad[idx] / (sqrt(g[idx]) + eps);
  }
}

template <typename T>
void AdagradCuda<T>::update_impl(const string &key, VariablePtr param) {
  Size_t size = param->size();
  VariablePtr g_ = this->state_.at(key);
  T *g = g_->cast_data_and_get_pointer<T>(this->ctx_);
  const T *grad = param->get_grad_pointer<T>(this->ctx_);
  T *data = param->cast_data_and_get_pointer<T>(this->ctx_);
  NBLA_CUDA_LAUNCH_KERNEL_SIMPLE(kernel_adagrad_update, size, data, grad, g,
                                 this->lr_, this->eps_);
}

NBLA_DEF_WEIGHT_DECAY(AdagradCuda, weight_decay_cuda);
}
