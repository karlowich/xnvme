# SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
#
# SPDX-License-Identifier: BSD-3-Clause

xnvmelib_libvfn_source = files(
  'xnvme_be_libvfn_admin.c',
  'xnvme_be_libvfn_async.c',
  'xnvme_be_libvfn_dev.c',
  'xnvme_be_libvfn_mem.c',
  'xnvme_be_libvfn_sync.c',
  'xnvme_be_libvfn.c',
)
xnvmelib_source += xnvmelib_libvfn_source

# Expose this backend's internal headers on the include path
conf_inc += [ include_directories('.') ]
