#!/bin/bash

COMPACT_JOB_NAME="${BUILD_ENVIRONMENT}-test"
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Required environment variable: $BUILD_ENVIRONMENT
# (This is set by default in the Docker images we build, so you don't
# need to set it yourself.

echo "Testing pytorch"

# JIT C++ extensions require ninja.
git clone https://github.com/ninja-build/ninja --quiet
pushd ninja
python ./configure.py --bootstrap
export PATH="$PWD:$PATH"
popd

# DANGER WILL ROBINSON.  The LD_PRELOAD here could cause you problems
# if you're not careful.  Check this if you made some changes and the
# ASAN test is not working
if [[ "$BUILD_ENVIRONMENT" == *asan* ]]; then
    export ASAN_OPTIONS=detect_leaks=0:symbolize=1
    export UBSAN_OPTIONS=print_stacktrace=1
    export PYTORCH_TEST_WITH_ASAN=1
    export PYTORCH_TEST_WITH_UBSAN=1
    # TODO: Figure out how to avoid hard-coding these paths
    export ASAN_SYMBOLIZER_PATH=/usr/lib/llvm-5.0/bin/llvm-symbolizer
    export LD_PRELOAD=/usr/lib/llvm-5.0/lib/clang/5.0.0/lib/linux/libclang_rt.asan-x86_64.so
    # Increase stack size, because ASAN red zones use more stack
    ulimit -s 81920

    function get_exit_code() {
      set +e
      "$@"
      retcode=$?
      set -e
      return $retcode
    }
    (cd test && python -c "import torch")
    echo "The next three invocations are expected to crash; if they don't that means ASAN/UBSAN is misconfigured"
    (cd test && ! get_exit_code python -c "import torch; torch._C._crash_if_csrc_asan(3)")
    (cd test && ! get_exit_code python -c "import torch; torch._C._crash_if_csrc_ubsan(0)")
    (cd test && ! get_exit_code python -c "import torch; torch._C._crash_if_aten_asan(3)")
fi

export ATEN_DISABLE_AVX=
export ATEN_DISABLE_AVX2=
if [[ "${JOB_BASE_NAME}" == *-NO_AVX-* ]]; then
  export ATEN_DISABLE_AVX=1
fi
if [[ "${JOB_BASE_NAME}" == *-NO_AVX2-* ]]; then
  export ATEN_DISABLE_AVX2=1
fi

test_python_nn() {
  time python test/run_test.py --include nn --verbose
}

test_python_all_except_nn() {
  time python test/run_test.py --exclude nn --verbose
}

test_aten() {
  # Test ATen
  if [[ "$BUILD_ENVIRONMENT" != *asan* ]]; then
    echo "Running ATen tests with pytorch lib"
    TORCH_LIB_PATH=$(python -c "import site; print(site.getsitepackages()[0])")/torch/lib
    # NB: the ATen test binaries don't have RPATH set, so it's necessary to
    # put the dynamic libraries somewhere were the dynamic linker can find them.
    # This is a bit of a hack.
    ln -s "$TORCH_LIB_PATH"/libcaffe2* build/bin
    ls build/bin
    aten/tools/run_tests.sh build/bin
  fi
}

test_torchvision() {
  rm -rf ninja

  echo "Installing torchvision at branch master"
  rm -rf vision
  # TODO: This git clone is bad, it means pushes to torchvision can break
  # PyTorch CI
  git clone https://github.com/pytorch/vision --quiet
  pushd vision
  # python setup.py install with a tqdm dependency is broken in the
  # Travis Python nightly (but not in latest Python nightlies, so
  # this should be a transient requirement...)
  # See https://github.com/pytorch/pytorch/issues/7525
  #time python setup.py install
  pip install .
  popd
}

test_libtorch() {
  if [[ "$BUILD_TEST_LIBTORCH" == "1" ]]; then
     echo "Testing libtorch"
     CPP_BUILD="$PWD/../cpp-build"
     if [[ "$BUILD_ENVIRONMENT" == *cuda* ]]; then
       "$CPP_BUILD"/libtorch/bin/test_jit
     else
       "$CPP_BUILD"/libtorch/bin/test_jit "[cpu]"
     fi
     python tools/download_mnist.py --quiet -d test/cpp/api/mnist
     OMP_NUM_THREADS=2 "$CPP_BUILD"/libtorch/bin/test_api
  fi
}

if [ -z "${JOB_BASE_NAME}" ] || [[ "${JOB_BASE_NAME}" == *-test ]]; then
  test_python_nn
  test_python_all_except_nn
  test_aten
  test_torchvision
  test_libtorch
else
  if [[ "${JOB_BASE_NAME}" == *-test1 ]]; then
    test_python_nn
  elif [[ "${JOB_BASE_NAME}" == *-test2 ]]; then
    test_python_all_except_nn
    test_aten
    test_torchvision
    test_libtorch
  fi
fi
