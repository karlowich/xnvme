# SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
#
# SPDX-License-Identifier: BSD-3-Clause

xnvmelib_cbi_source = files(
  'xnvme_be_cbi_admin_shim.c',
  'xnvme_be_cbi_async_emu.c',
  'xnvme_be_cbi_async_nil.c',
  'xnvme_be_cbi_async_posix.c',
  'xnvme_be_cbi_async_thrpool.c',
  'xnvme_be_cbi_mem_posix.c',
  'xnvme_be_cbi_sync_psync.c',
)
xnvmelib_source += xnvmelib_cbi_source

# Expose this backend's internal headers on the include path
conf_inc += [ include_directories('.') ]
