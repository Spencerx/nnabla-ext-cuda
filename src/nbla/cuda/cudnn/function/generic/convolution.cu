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

// convolution_cudnn.cu

#include <nbla/array.hpp>
#include <nbla/cuda/array/cuda_array.hpp>
#include <nbla/cuda/common.hpp>
#include <nbla/cuda/cudnn/cudnn.hpp>
#include <nbla/cuda/cudnn/function/convolution.hpp>
#include <nbla/variable.hpp>

namespace nbla {

template <typename T>
void ConvolutionCudaCudnn<T>::setup_impl(const Variables &inputs,
                                         const Variables &outputs) {
  cuda_set_device(device_);
  Convolution<T>::setup_impl(inputs, outputs);
  cudnn_handle_ = SingletonManager::get<CudnnHandleManager>()->handle(device_);

  x_offset_ = this->inner_size_i_ / this->group_;
  y_offset_ = this->inner_size_o_ / this->group_;
  w_offset_ = this->channels_o_ * this->inner_size_k_ / this->group_;
  if (inputs.size() == 3) {
    b_offset_ = this->channels_o_ / this->group_;
  }
  // Create or query a resource.
  CudnnConvDesc desc{(int)this->kernel_.size(),
                     device_,
                     cudnn_data_type<T>::type(),
                     CUDNN_CROSS_CORRELATION,
                     this->outer_size_,
                     this->channels_i_,
                     this->channels_o_,
                     this->group_,
                     this->spatial_shape_i_,
                     this->kernel_,
                     this->pad_,
                     this->stride_,
                     this->dilation_};

  auto &rsc = SingletonManager::get<CudnnHandleManager>()->conv_resource;
  auto it = rsc.find(desc);
  if (it != rsc.end()) {
    // Found a previously created one.
    // std::cout << "Found previously created one: " << desc << std::endl;
    rsc_ = it->second;
    return;
  }
  // Create a new resource.
  // This will search a best algorithm given config.
  rsc_ = make_shared<CudnnConvResource>(desc);
  rsc.insert({desc, rsc_}); // Register the created resource to global.
}

template <class T>
void ConvolutionCudaCudnn<T>::forward_impl(const Variables &inputs,
                                           const Variables &outputs) {
  cuda_set_device(std::stoi(this->ctx_.device_id));
  const Tw *x = inputs[0]->get_data_pointer<Tw>(this->ctx_);
  const Tw *w = inputs[1]->get_data_pointer<Tw>(this->ctx_);
  Tw *y = outputs[0]->cast_data_and_get_pointer<Tw>(this->ctx_, true);
  auto alpha = get_cudnn_scalar_arg<T>(1);
  auto beta = get_cudnn_scalar_arg<T>(0);
  const Tw *b;
  if (inputs.size() == 3) {
    b = inputs[2]->get_data_pointer<Tw>(this->ctx_);
  }
  void *workspace = SingletonManager::get<Cuda>()->get_workspace(
      rsc_->workspace_size(), this->device_);
  for (int g = 0; g < this->group_; ++g) {
    NBLA_CUDNN_CHECK(cudnnConvolutionForward(
        cudnn_handle_, &alpha, rsc_->x_desc, x + x_offset_ * g, rsc_->w_desc,
        w + w_offset_ * g, rsc_->conv_desc, rsc_->fwd_algo, workspace,
        rsc_->fwd_workspace_size, &beta, rsc_->y_desc, y + y_offset_ * g));
    if (inputs.size() == 3) {
      // TODO: Bias addition should be outside of the loop. In that case,
      // b_desc and y_desc must be whole image descriptor.
      NBLA_CUDNN_CHECK(cudnnAddTensor(cudnn_handle_, &alpha, rsc_->b_desc,
                                      b + b_offset_ * g, &alpha, rsc_->y_desc,
                                      y + y_offset_ * g));
    }
  }
}

template <class T>
void ConvolutionCudaCudnn<T>::backward_impl(const Variables &inputs,
                                            const Variables &outputs,
                                            const vector<bool> &propagate_down,
                                            const vector<bool> &accum) {

  if (!(propagate_down[0] || propagate_down[1] ||
        (inputs.size() == 3 && propagate_down[2]))) {
    return;
  }
  cuda_set_device(std::stoi(this->ctx_.device_id));
  const T *dy = outputs[0]->get_grad_pointer<T>(this->ctx_);
  const T *x;
  const T *w;
  T *dx, *dw, *db;
  if (propagate_down[0]) {
    w = inputs[1]->get_data_pointer<T>(this->ctx_);
    dx = inputs[0]->cast_grad_and_get_pointer<T>(this->ctx_, !accum[0]);
  }
  if (propagate_down[1]) {
    x = inputs[0]->get_data_pointer<T>(this->ctx_);
    dw = inputs[1]->cast_grad_and_get_pointer<T>(this->ctx_, !accum[1]);
  }
  if (propagate_down[2]) {
    db = inputs[2]->cast_grad_and_get_pointer<T>(this->ctx_, !accum[2]);
  }
  auto alpha = get_cudnn_scalar_arg<T>(1);
  void *workspace = SingletonManager::get<Cuda>()->get_workspace(
      rsc_->workspace_size(), this->device_);
  for (int g = 0; g < this->group_; ++g) {
    if (propagate_down[0]) {
      auto beta = get_cudnn_scalar_arg<T>(accum[0] ? 1 : 0);
      NBLA_CUDNN_CHECK(cudnnConvolutionBackwardData(
          cudnn_handle_, &alpha, rsc_->w_desc, w + w_offset_ * g, rsc_->y_desc,
          dy + y_offset_ * g, rsc_->conv_desc, rsc_->bwd_data_algo, workspace,
          rsc_->bwd_data_workspace_size, &beta, rsc_->x_desc,
          dx + x_offset_ * g));
    }
    if (propagate_down[1]) {
      auto beta = get_cudnn_scalar_arg<T>(accum[1] ? 1 : 0);
      NBLA_CUDNN_CHECK(cudnnConvolutionBackwardFilter(
          cudnn_handle_, &alpha, rsc_->x_desc, x + x_offset_ * g, rsc_->y_desc,
          dy + y_offset_ * g, rsc_->conv_desc, rsc_->bwd_filter_algo, workspace,
          rsc_->bwd_filter_workspace_size, &beta, rsc_->w_desc,
          dw + w_offset_ * g));
    }
    if (inputs.size() == 3 && propagate_down[2]) {
      auto beta = get_cudnn_scalar_arg<T>(accum[2] ? 1 : 0);
      NBLA_CUDNN_CHECK(cudnnConvolutionBackwardBias(
          cudnn_handle_, &alpha, rsc_->y_desc, dy + y_offset_ * g, &beta,
          rsc_->b_desc, db + b_offset_ * g));
    }
  }
}

// Manually selecting algorithms is not supported for now.
/*
// Basically this functions is not invoked,
// because it is choosen by cudnnGetConvolutionForwardAlgorithm()
template <class T>
void ConvolutionCudaCudnn<T>::set_cudnn_convolution_forward_algorithm(
    std::string algorithm) {
  if (algorithm == "ALGO_IMPLICIT_GEMM") {
    fwd_algo_ = CUDNN_CONVOLUTION_FWD_ALGO_IMPLICIT_GEMM;
  } else if (algorithm == "ALGO_IMPLICIT_PRECOMP_GEMM") {
    fwd_algo_ = CUDNN_CONVOLUTION_FWD_ALGO_IMPLICIT_PRECOMP_GEMM;
  } else if (algorithm == "ALGO_GEMM") {
    fwd_algo_ = CUDNN_CONVOLUTION_FWD_ALGO_GEMM;
  } else if (algorithm == "ALGO_DIRECT") {
    fwd_algo_ = CUDNN_CONVOLUTION_FWD_ALGO_DIRECT;
  } else if (algorithm == "ALGO_FFT") {
    fwd_algo_ = CUDNN_CONVOLUTION_FWD_ALGO_FFT;
  } else if (algorithm == "ALGO_FFT_TILING") {
    fwd_algo_ = CUDNN_CONVOLUTION_FWD_ALGO_FFT_TILING;
  }
#if CUDNN_VERSION >= 5000
  else if (algorithm == "ALGO_WINOGRAD") {
    fwd_algo_ = CUDNN_CONVOLUTION_FWD_ALGO_WINOGRAD;
  }
#endif
  else {
    NBLA_ERROR(error_code::target_specific,
               "Specified unsupported forward algorithm");
  }
}

// Basically this functions is not invoked,
// because it is choosen by cudnnGetConvolutionBackwardFilterAlgorithm()
template <class T>
void ConvolutionCudaCudnn<T>::set_cudnn_convolution_backward_filter_algorithm(
    std::string algorithm) {
  if (algorithm == "ALGO_0") {
    bwd_filter_algo_ = CUDNN_CONVOLUTION_BWD_FILTER_ALGO_0;
  } else if (algorithm == "ALGO_1") {
    bwd_filter_algo_ = CUDNN_CONVOLUTION_BWD_FILTER_ALGO_1;
  } else if (algorithm == "ALGO_FFT") {
    bwd_filter_algo_ = CUDNN_CONVOLUTION_BWD_FILTER_ALGO_FFT;
  } else if (algorithm == "ALGO_3") {
    bwd_filter_algo_ = CUDNN_CONVOLUTION_BWD_FILTER_ALGO_3;
  }
#if CUDNN_VERSION >= 5100
  else if (algorithm == "ALGO_WINOGRAD_NONFUSED") {
    bwd_filter_algo_ = CUDNN_CONVOLUTION_BWD_FILTER_ALGO_WINOGRAD_NONFUSED;
  }
#endif
  else {
    NBLA_ERROR(error_code::target_specific,
               "Specified unsupported backward filter algorithm");
  }
}

// Basically this functions is not invoked,
// because it is choosen by cudnnGetConvolutionBackwardDataAlgorithm()
template <class T>
void ConvolutionCudaCudnn<T>::set_cudnn_convolution_backward_data_algorithm(
    std::string algorithm) {
  if (algorithm == "ALGO_0") {
    bwd_data_algo_ = CUDNN_CONVOLUTION_BWD_DATA_ALGO_0;
  } else if (algorithm == "ALGO_1") {
    bwd_data_algo_ = CUDNN_CONVOLUTION_BWD_DATA_ALGO_1;
  } else if (algorithm == "ALGO_FFT") {
    bwd_data_algo_ = CUDNN_CONVOLUTION_BWD_DATA_ALGO_FFT;
  } else if (algorithm == "ALGO_FFT_TILING") {
    bwd_data_algo_ = CUDNN_CONVOLUTION_BWD_DATA_ALGO_FFT_TILING;
  }
#if CUDNN_VERSION >= 5000
  else if (algorithm == "ALGO_WINOGRAD") {
    bwd_data_algo_ = CUDNN_CONVOLUTION_BWD_DATA_ALGO_WINOGRAD;
  }
#if CUDNN_VERSION >= 5100
  else if (algorithm == "ALGO_WINOGRAD_NONFUSED") {
    bwd_data_algo_ = CUDNN_CONVOLUTION_BWD_DATA_ALGO_WINOGRAD_NONFUSED;
  }
#endif
#endif
  else {
    NBLA_ERROR(error_code::target_specific,
               "Specified unsupported backward data algorithm");
  }
}

template <class T>
void ConvolutionCudaCudnn<T>::set_cudnn_convolution_mode(std::string mode) {
  if (mode == "CONVOLUTION") {
    mode_ = CUDNN_CONVOLUTION;
  } else if (mode == "CROSS_CORRELATION") {
    mode_ = CUDNN_CROSS_CORRELATION;
  } else {
    NBLA_ERROR(error_code::target_specific, "Specified unsupported algorithm");
  }
}
*/
}
