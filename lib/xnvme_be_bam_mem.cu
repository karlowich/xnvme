// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

extern "C" {
#include <xnvme_be.h>
#include <xnvme_be_nosys.h>
}
#ifdef XNVME_BE_BAM_ENABLED
#include <errno.h>
#include <linux/dma-buf.h>
#include <linux/udmabuf.h>
#include <sys/ioctl.h>
#include <xnvme_be_bam.h>
#include <xnvme_dev.h>


__device__ __host__ static int
_cmp(const void *vaddr, const struct skiplist_node *n)
{
	struct xnvme_be_bam_memory *m = container_of(n, struct xnvme_be_bam_memory, list);
	uint64_t a = (uint64_t) vaddr;
	uint64_t b = (uint64_t) m->vaddr;

	if (a < b)
		return -1;
	else if (a >= b + m->n_addrs*m->page_size)
		return 1;

	return 0;
}

__device__ __host__ struct xnvme_be_bam_memory *
xnvme_be_bam_memory_find(struct xnvme_be_bam_state *state, void *buf)
{
	return container_of_or_null(skiplist_find(state->list, buf, _cmp, NULL), struct xnvme_be_bam_memory, list);
}

static int
xnvme_be_bam_dmabuf_detach(xnvme_be_bam_memory *mem) {
	int udmabuf_fd, err;

  udmabuf_fd = open("/dev/udmabuf", O_RDWR);
  if (udmabuf_fd < 0) {
		err = -errno;
    XNVME_DEBUG("FAILED: could not open udmabuf dev, errno: %d", err);
    return err;
  }

  err = ioctl(udmabuf_fd, UDMABUF_DETACH, &mem->dmabuf_fd);
  if (err) {
    err = -errno;
    XNVME_DEBUG("FAILED: IOCTL UDMABUF_DETACH, errno: %d\n", err);
    return err;
  }

  close(udmabuf_fd);
  return 0;
}

static int
xnvme_be_bam_dmabuf_attach(xnvme_be_bam_memory *mem) {
  struct udmabuf_attach attach;
  struct udmabuf_get_map *map;
	int udmabuf_fd, err, i = 0;
	size_t map_size;

  udmabuf_fd = open("/dev/udmabuf", O_RDWR);
  if (udmabuf_fd < 0) {
		err = -errno;
    XNVME_DEBUG("FAILED: could not open udmabuf dev, errno: %d", err);
    return err;
  }

  memset(&attach, 0, sizeof(attach));
  attach.fd = mem->dmabuf_fd;

  err = ioctl(udmabuf_fd, UDMABUF_ATTACH, &attach);
  if (err) {
    err = -errno;
    XNVME_DEBUG("FAILED: IOCTL UDMABUF_ATTACH, errno: %d\n", err);
    goto exit;
  }

  map_size = attach.count * sizeof(struct udmabuf_dma_map);

  map = (udmabuf_get_map *) malloc(sizeof(struct udmabuf_get_map) + map_size);
  if (!map) {
		err = -errno;
    XNVME_DEBUG("FAILED: could not to alloc get_map struct, errno: %d", err);
    goto exit;
  }
  memset(map, 0, sizeof(*map));

  map->fd = mem->dmabuf_fd;
  map->count = attach.count;

  err = ioctl(udmabuf_fd, UDMABUF_GET_MAP, map);
  if (err) {
    err = -errno;
    XNVME_DEBUG("FAILED: IOCTL UDMABUF_GET_MAP, errno: %d\n", err);
    goto exit;
  }

  for (uint32_t j = 0; j < map->count; j++) {
		// handle a single address for multiple pages
		for (uint64_t k = 0; k < map->dma_arr[j].dma_len / mem->page_size; k++) {
	    mem->addrs[i] = map->dma_arr[j].dma_addr + k * mem->page_size;
	    i++;
		}
  }

exit:
  free(map);
  close(udmabuf_fd);

	return err;
}

void *
xnvme_be_bam_gpu_buf_alloc(const struct xnvme_dev *dev, size_t nbytes, uint64_t *XNVME_UNUSED(phys))
{
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state *)dev->be.state;
	struct skiplist_node *update[SKIPLIST_LEVELS] = {};
	struct xnvme_be_bam_memory *mem;
	CUdeviceptr vaddr;
	size_t mem_size;
	int dmabuf_fd, err;

	size_t page_size = 1 << 16; // 64K
	size_t buf_size = NVM_PAGE_ALIGN(nbytes, page_size);
	uint32_t n_addrs = buf_size / page_size;

	err =	cuMemAlloc(&vaddr, buf_size);
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		return NULL;
	}

	if (skiplist_find(state->list, (void *)vaddr, _cmp, update)) {
		XNVME_DEBUG("FAILED: vaddr already exist in the skiplist");
		goto error;
	}
	err = cuMemGetHandleForAddressRange(&dmabuf_fd, vaddr, buf_size,
                                      CU_MEM_RANGE_HANDLE_TYPE_DMA_BUF_FD, 0);
  if (err) {
		XNVME_DEBUG("FAILED: could not get dmabuf_fd, err: %d", err);
		goto error;
  }

	mem_size = NVM_PAGE_ALIGN(sizeof(struct xnvme_be_bam_memory) + n_addrs * sizeof(uint64_t), page_size);
	err = cudaMallocManaged(&mem, mem_size);
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		goto error;
	}

	mem->vaddr = (void *) vaddr;
	mem->dmabuf_fd = dmabuf_fd;
	mem->page_size = page_size;
	mem->n_addrs = n_addrs;
	err = xnvme_be_bam_dmabuf_attach(mem);
	if (err) {
		XNVME_DEBUG("FAILED: could not get dma addresses, err: %d", err);
		goto error;
	}

	skiplist_link(state->list, &mem->list, update);
	return mem->vaddr;

error:
	cuMemFree(vaddr);
	cudaFree(mem);
	return NULL;
}

void
xnvme_be_bam_gpu_buf_free(const struct xnvme_dev *dev, void *buf)
{
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state *)dev->be.state;
	struct skiplist_node *update[SKIPLIST_LEVELS] = {};
	struct xnvme_be_bam_memory *mem;

	mem = container_of_or_null(skiplist_find(state->list, buf, _cmp, update), struct xnvme_be_bam_memory, list);
	if (!mem) {
		XNVME_DEBUG("FAILED: couldn't find memory in skiplist");
		return;
	}

	skiplist_erase(state->list, &mem->list, update);
	xnvme_be_bam_dmabuf_detach(mem);
	cuMemFree((CUdeviceptr) mem->vaddr);
	cudaFree(mem);
}

static int
xnvme_be_bam_cpu_create_dmabuf(int *dmabuf_fd, void **vaddr, size_t buf_size)
{
  struct udmabuf_create create;
	int udmabuf_fd, memfd, err;
	memfd = memfd_create("xnvme_be_bam", MFD_ALLOW_SEALING);
  if (memfd < 0) {
    err = -errno;
    XNVME_DEBUG("FAILED: couldn't create memfd, errno: %d", err);
    return err;
  }

  err = fcntl(memfd, F_ADD_SEALS, F_SEAL_SHRINK);
  if (err) {
		err = -errno;
    XNVME_DEBUG("FAILED: couldn't set seals on memfd, errno: %d", err);
    return err;
  }

  err = ftruncate(memfd, buf_size);
  if (err) {
    err = -errno;
    XNVME_DEBUG("FAILED: couldn't resize memfd, errno: %d", err);
    return err;
  }

  udmabuf_fd = open("/dev/udmabuf", O_RDWR);
  if (udmabuf_fd < 0) {
  	err = -errno;
    XNVME_DEBUG("FAILED: could not open udmabuf dev, errno: %d", err);
    return err;
  }

  memset(&create, 0, sizeof(create));
  create.memfd = memfd;
  create.offset = 0;
  create.size = buf_size;
  *dmabuf_fd = ioctl(udmabuf_fd, UDMABUF_CREATE, &create);
  if (*dmabuf_fd < 0) {
    err = -errno;
    XNVME_DEBUG("FAILED: couldn't create udmabuf, errno: %d", err);
    return err;
  }

  close(udmabuf_fd);

  *vaddr = mmap(NULL, buf_size, PROT_READ | PROT_WRITE, MAP_SHARED, *dmabuf_fd, 0);
  if (!(*vaddr)) {
    err = -errno;
    XNVME_DEBUG("FAILED: couldn't mmap udmabuf, errno: %d\n", err);
    return err;
  }

  return 0;
}

void *
xnvme_be_bam_cpu_buf_alloc(const struct xnvme_dev *dev, size_t nbytes, uint64_t *XNVME_UNUSED(phys))
{
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state *)dev->be.state;
	struct skiplist_node *update[SKIPLIST_LEVELS] = {};
	struct xnvme_be_bam_memory *mem;
	void *vaddr;
	size_t mem_size;
	int err, dmabuf_fd = 0;

	size_t page_size = 1 << 12; // 4K
	size_t buf_size = NVM_PAGE_ALIGN(nbytes, page_size);
	uint32_t n_addrs = buf_size / page_size;

	err = xnvme_be_bam_cpu_create_dmabuf(&dmabuf_fd, &vaddr, buf_size);
	if (err) {
		XNVME_DEBUG("FAILED: couldn't create dmabuf");
		return NULL;
	}

	if (skiplist_find(state->list, vaddr, _cmp, update)) {
			XNVME_DEBUG("FAILED: buf already exist in the skiplist");
			return NULL;
	}

	mem_size = NVM_PAGE_ALIGN(sizeof(struct xnvme_be_bam_memory) + n_addrs * sizeof(uint64_t), 1<<16); // Align GPU allocation to 64K
	err = cudaMallocManaged(&mem, mem_size);
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		return NULL;
	}
	mem->vaddr = vaddr;
	mem->dmabuf_fd = dmabuf_fd;
	mem->page_size = page_size;
	mem->n_addrs = n_addrs;

	err = xnvme_be_bam_dmabuf_attach(mem);
	if (err) {
		XNVME_DEBUG("FAILED: could not get dma addresses, err: %d", err);
		return NULL;
	}

	skiplist_link(state->list, &mem->list, update);
	return mem->vaddr;
}

void
xnvme_be_bam_cpu_buf_free(const struct xnvme_dev *dev, void *buf)
{
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state *)dev->be.state;
	struct skiplist_node *n, *update[SKIPLIST_LEVELS] = {};
	struct xnvme_be_bam_memory *mem;

	n = skiplist_find(state->list, buf, _cmp, update);
	if (!n) {
		XNVME_DEBUG("FAILED: couldn't find memory in skiplist");
		return;
	}

	skiplist_erase(state->list, n, update);
	mem = container_of_or_null(n, struct xnvme_be_bam_memory, list);
	if (!mem) {
		XNVME_DEBUG("FAILED: couldn't find memory from skiplist node");
		return;
	}
	xnvme_be_bam_dmabuf_detach(mem);
	cudaFree(mem);
}
#endif

struct xnvme_be_mem g_xnvme_be_cpu_mem = {
#ifdef XNVME_BE_BAM_ENABLED
	.buf_alloc = xnvme_be_bam_cpu_buf_alloc,
	.buf_vtophys = xnvme_be_nosys_buf_vtophys,
	.buf_realloc = xnvme_be_nosys_buf_realloc,
	.buf_free = xnvme_be_bam_cpu_buf_free,
	.mem_map = xnvme_be_nosys_mem_map,
	.mem_unmap = xnvme_be_nosys_mem_unmap,
#else
	.buf_alloc = xnvme_be_nosys_buf_alloc,
	.buf_vtophys = xnvme_be_nosys_buf_vtophys,
	.buf_realloc = xnvme_be_nosys_buf_realloc,
	.buf_free = xnvme_be_nosys_buf_free,
	.mem_map = xnvme_be_nosys_mem_map,
	.mem_unmap = xnvme_be_nosys_mem_unmap,
#endif
	.id = "cpu",
};

struct xnvme_be_mem g_xnvme_be_gpu_mem = {
#ifdef XNVME_BE_BAM_ENABLED
	.buf_alloc = xnvme_be_bam_gpu_buf_alloc,
	.buf_vtophys = xnvme_be_nosys_buf_vtophys,
	.buf_realloc = xnvme_be_nosys_buf_realloc,
	.buf_free = xnvme_be_bam_gpu_buf_free,
	.mem_map = xnvme_be_nosys_mem_map,
	.mem_unmap = xnvme_be_nosys_mem_unmap,
#else
	.buf_alloc = xnvme_be_nosys_buf_alloc,
	.buf_vtophys = xnvme_be_nosys_buf_vtophys,
	.buf_realloc = xnvme_be_nosys_buf_realloc,
	.buf_free = xnvme_be_nosys_buf_free,
	.mem_map = xnvme_be_nosys_mem_map,
	.mem_unmap = xnvme_be_nosys_mem_unmap,
#endif
	.id = "gpu",
};
