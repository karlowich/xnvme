# SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
#
# SPDX-License-Identifier: BSD-3-Clause

xnvmelib_spdk_source = files(
  'xnvme_be_spdk_admin.c',
  'xnvme_be_spdk_async.c',
  'xnvme_be_spdk_dev.c',
  'xnvme_be_spdk_mem.c',
  'xnvme_be_spdk_sync.c',
  'xnvme_be_spdk.c',
)
xnvmelib_source += xnvmelib_spdk_source

# Expose this backend's internal headers on the include path
conf_inc += [ include_directories('.') ]
