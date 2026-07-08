# SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
#
# SPDX-License-Identifier: BSD-3-Clause

xnvmelib_freebsd_source = files(
  'xnvme_be_freebsd_async.c',
  'xnvme_be_freebsd_dev.c',
  'xnvme_be_freebsd_nvme.c',
  'xnvme_be_freebsd.c',
)
xnvmelib_source += xnvmelib_freebsd_source

# Expose this backend's internal headers on the include path
conf_inc += [ include_directories('.') ]
