# SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
#
# SPDX-License-Identifier: BSD-3-Clause

xnvmelib_linux_source = files(
  'xnvme_be_linux_async_libaio.c',
  'xnvme_be_linux_async_liburing.c',
  'xnvme_be_linux_async_ucmd.c',
  'xnvme_be_linux_block.c',
  'xnvme_be_linux_dev.c',
  'xnvme_be_linux_hugepage.c',
  'xnvme_be_linux_nvme.c',
  'xnvme_be_linux.c',
)
xnvmelib_source += xnvmelib_linux_source

# Expose this backend's internal headers on the include path
conf_inc += [ include_directories('.') ]
