# SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
#
# SPDX-License-Identifier: BSD-3-Clause

xnvmelib_macos_source = files(
  'xnvme_be_macos_admin.c',
  'xnvme_be_macos_dev.c',
  'xnvme_be_macos_driverkit_admin.c',
  'xnvme_be_macos_driverkit_async.c',
  'xnvme_be_macos_driverkit_dev.c',
  'xnvme_be_macos_driverkit_mem.c',
  'xnvme_be_macos_driverkit_sync.c',
  'xnvme_be_macos_driverkit.c',
  'xnvme_be_macos_sync.c',
  'xnvme_be_macos.c',
)
xnvmelib_source += xnvmelib_macos_source

# Expose this backend's internal headers on the include path
conf_inc += [ include_directories('.') ]
