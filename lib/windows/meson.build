# SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
#
# SPDX-License-Identifier: BSD-3-Clause

xnvmelib_windows_source = files(
  'xnvme_be_windows_async_iocp_th.c',
  'xnvme_be_windows_async_iocp.c',
  'xnvme_be_windows_async_ioring.c',
  'xnvme_be_windows_block.c',
  'xnvme_be_windows_dev.c',
  'xnvme_be_windows_fs.c',
  'xnvme_be_windows_mem.c',
  'xnvme_be_windows_nvme.c',
  'xnvme_be_windows.c',
)
xnvmelib_source += xnvmelib_windows_source

# Expose this backend's internal headers on the include path
conf_inc += [ include_directories('.') ]
