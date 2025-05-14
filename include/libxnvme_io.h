/**
 * SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
 *
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * @headerfile libxnvme_io.h
 */

int
xnvme_io_range_submit(struct xnvme_queue *queue, uint32_t opc, uint32_t *slbas, uint32_t *elbas,
		      uint32_t nlb, uint64_t nbytes, void **dbufs, uint32_t n_ranges);
