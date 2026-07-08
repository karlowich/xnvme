# SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
#
# SPDX-License-Identifier: BSD-3-Clause

xnvmelib_ramdisk_source = files(
  'xnvme_be_ramdisk_admin.c',
  'xnvme_be_ramdisk_dev.c',
  'xnvme_be_ramdisk_sync.c',
  'xnvme_be_ramdisk.c',
)
xnvmelib_source += xnvmelib_ramdisk_source

# Expose this backend's internal headers on the include path
conf_inc += [ include_directories('.') ]
