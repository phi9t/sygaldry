# Zephyr Spack Dependency Graph (Concretized)

**Source:** `pkg/zephyr/spack.lock` and `pkg/zephyr/spack.yaml`

## Graph Summary

- Total concrete specs (nodes): **270**
- Total dependency edges: **2032**
- Root specs: **24**

### Root Specs

- openssh
- py-jupyterlab
- py-pandas
- fd
- py-jaxlib+cuda cuda_arch=61,75,80,86,89,90
- gdb
- python-venv
- py-pip
- htop
- llvm+clang+lldb
- eigen
- ripgrep
- py-torch+cuda cuda_arch=61,75,80,86,89,90
- py-numpy
- py-jax
- lapack
- openblas
- python
- git
- py-torchvision
- tmux
- py-scipy
- py-scikit-learn
- py-matplotlib

### External Packages

- gcc@13.3.0
- glibc@2.39

### Top Outgoing Dependency Counts

- py-torch@2.9.0: 42 deps
- py-matplotlib@3.10.7: 25 deps
- py-jupyter-server@2.17.0: 23 deps
- py-jupyterlab@4.4.10: 21 deps
- git@2.48.1: 20 deps
- py-nbconvert@7.16.6: 20 deps
- py-jsonschema@4.25.1: 19 deps
- llvm@21.1.4: 19 deps
- python@3.13.8: 18 deps
- elfutils@0.193: 18 deps

### Top Incoming Dependency Counts (Most Depended-On)

- python@3.13.8: 166 dependents
- python-venv@1.0: 155 dependents
- py-pip@25.1.1: 154 dependents
- py-wheel@0.45.1: 152 dependents
- gcc@13.3.0: 134 dependents
- glibc@2.39: 134 dependents
- compiler-wrapper@1.0: 133 dependents
- gcc-runtime@13.3.0: 133 dependents
- py-setuptools@79.0.1: 91 dependents
- gmake@4.4.1: 90 dependents

## Key Subgraphs (Direct Dependencies)

### py-torch

- binutils@2.45
- cmake@3.31.9
- compiler-wrapper@1.0
- cpuinfo@2025-03-21
- cuda@12.9.1
- cudnn@9.8.0.87-12
- cusparselt@0.8.1-cuda120
- eigen@5.0.0
- fp16@2020-05-14
- fxdiv@2020-04-17
- gcc-runtime@13.3.0
- gcc@13.3.0
- glibc@2.39
- ninja@1.13.0
- numactl@2.0.18
- nvtx@3.2.1
- openblas@0.3.30
- openmpi@5.0.8
- protobuf@3.13.0
- psimd@2020-05-17
- pthreadpool@2023-08-29
- py-filelock@3.19.1
- py-fsspec@2025.9.0
- py-jinja2@3.1.6
- py-networkx@3.5
- py-numpy@2.3.4
- py-packaging@25.0
- py-pip@25.1.1
- py-protobuf@3.13.0
- py-pybind11@3.0.1
- py-pyyaml@6.0.3
- py-requests@2.32.5
- py-setuptools@79.0.1
- py-six@1.17.0
- py-sympy@1.13.3
- py-tqdm@4.67.1
- py-typing-extensions@4.14.1
- py-wheel@0.45.1
- python-venv@1.0
- python@3.13.8
- sleef@3.8
- valgrind@3.25.1

### py-jax

- py-jaxlib@0.7.0
- py-ml-dtypes@0.5.1
- py-numpy@2.3.4
- py-opt-einsum@3.4.0
- py-pip@25.1.1
- py-scipy@1.16.3
- py-setuptools@79.0.1
- py-wheel@0.45.1
- python-venv@1.0
- python@3.13.8

### py-jaxlib

- bazel@7.4.1
- compiler-wrapper@1.0
- cuda@12.9.1
- cudnn@9.8.0.87-12
- gcc-runtime@13.3.0
- gcc@13.3.0
- glibc@2.39
- py-build@1.2.2
- py-ml-dtypes@0.5.1
- py-numpy@2.3.4
- py-pip@25.1.1
- py-scipy@1.16.3
- py-setuptools@79.0.1
- py-wheel@0.45.1
- python-venv@1.0
- python@3.13.8

### python

- bzip2@1.0.8
- compiler-wrapper@1.0
- expat@2.7.3
- gcc-runtime@13.3.0
- gcc@13.3.0
- gdbm@1.25
- gettext@0.23.1
- glibc@2.39
- gmake@4.4.1
- libffi@3.5.2
- ncurses@6.5-20250705
- openssl@3.6.0
- pkgconf@2.5.1
- readline@8.3
- sqlite@3.50.4
- util-linux-uuid@2.41
- xz@5.6.3
- zlib-ng@2.2.4

### cuda

- libxml2@2.13.5

### cudnn

- cuda@12.9.1

### llvm

- binutils@2.45
- cmake@3.31.9
- compiler-wrapper@1.0
- gcc-runtime@13.3.0
- gcc@13.3.0
- glibc@2.39
- hwloc@2.12.2
- libedit@3.1-20240808
- libffi@3.5.2
- libxml2@2.13.5
- lua@5.3.6
- ncurses@6.5-20250705
- ninja@1.13.0
- perl-data-dumper@2.173
- pkgconf@2.5.1
- python@3.13.8
- swig@4.1.1
- xz@5.6.3
- zlib-ng@2.2.4

### openblas

- compiler-wrapper@1.0
- gcc-runtime@13.3.0
- gcc@13.3.0
- glibc@2.39
- gmake@4.4.1

## CUDA Stack (Detected Packages)

- cuda@12.9.1
- cudnn@9.8.0.87-12

## ML Frameworks (Resolved Versions)

- py-torch@2.9.0
- py-jax@0.7.0
- py-jaxlib@0.7.0
- py-torchvision@0.24.0

## Python Ecosystem (Selected)

- python@3.13.8
- py-numpy@2.3.4
- py-scipy@1.16.3
- py-pandas@2.3.3
- py-matplotlib@3.10.7
- py-scikit-learn@1.7.0
- py-jupyterlab@4.4.10
