#include <torch/extension.h>
#include <iostream>
#include <cstdint>
#include <tuple>

#include "utils.cuh"


// BEGIN KERNELS


__global__ void count_vertices_faces_kernel(
    const torch::PackedTensorAccessor32<float, 3, torch::RestrictPtrTraits> density_grid,
    const float thresh,
    // output
    int32_t* __restrict__ counters
) {
	const int32_t x = blockIdx.x * blockDim.x + threadIdx.x;
	const int32_t y = blockIdx.y * blockDim.y + threadIdx.y;
	const int32_t z = blockIdx.z * blockDim.z + threadIdx.z;

    const int32_t res_x = density_grid.size(0),
                  res_y = density_grid.size(1),
                  res_z = density_grid.size(2);
    // const int32_t res_x = resolution[0], res_y = resolution[1], res_z = resolution[2];
    if (x >= res_x || y >= res_y || z >= res_z) { return; }

    // traverse throught x-y-z axis
    const float density_self = density_grid[x][y][z];
    const bool inside = density_self > thresh;

    // ** vertices
    // x-axis
    if (x < res_x - 1) {
        const float density_x_next = density_grid[x + 1][y][z];
        const bool inside_x_next = (density_x_next > thresh);
        if (inside != inside_x_next) {
            atomicAdd(counters, 1);
        }
    }
    // y-axis
    if (y < res_y - 1) {
        const float density_y_next = density_grid[x][y + 1][z];
        const bool inside_y_next = (density_y_next > thresh);
        if (inside != inside_y_next) {
            atomicAdd(counters, 1);
        }
    }
    // z-axis
    if (z < res_z - 1) {
        const float density_z_next = density_grid[x][y][z + 1];
        const bool inside_z_next = (density_z_next > thresh);
        if (inside != inside_z_next) {
            atomicAdd(counters, 1);
        }
    }

    // ** faces
    if (x < res_x - 1 && y < res_y - 1 && z < res_z - 1) {
        uint8_t mask = 0;
        if (density_grid[x][y][z]             > thresh) { mask |= 1; }
        if (density_grid[x + 1][y][z]         > thresh) { mask |= 2; }
        if (density_grid[x + 1][y + 1][z]     > thresh) { mask |= 4; }
        if (density_grid[x][y + 1][z]         > thresh) { mask |= 8; }
        if (density_grid[x][y][z + 1]         > thresh) { mask |= 16; }
        if (density_grid[x + 1][y][z + 1]     > thresh) { mask |= 32; }
        if (density_grid[x + 1][y + 1][z + 1] > thresh) { mask |= 64; }
        if (density_grid[x][y + 1][z + 1]     > thresh) { mask |= 128; }

        // if (!mask || mask == 255) { return; }
        
        int32_t tricount = 0; // init outside for atomicAdd
        const int8_t *triangles = triangle_table[mask];
        for (; tricount < 15; tricount += 3) {
            if (triangles[tricount] < 0) { break; }
        }
        atomicAdd(counters + 1, tricount);
    }
}


__global__ void gen_vertices_kernel(
    const torch::PackedTensorAccessor32<float, 3, torch::RestrictPtrTraits> density_grid,
    const float thresh,
    // output
    torch::PackedTensorAccessor32<int32_t, 4, torch::RestrictPtrTraits> vertex_grid,
    torch::PackedTensorAccessor32<float, 2, torch::RestrictPtrTraits> vertices,
    int32_t* __restrict__ counters
) {
	const int32_t x = blockIdx.x * blockDim.x + threadIdx.x;
	const int32_t y = blockIdx.y * blockDim.y + threadIdx.y;
	const int32_t z = blockIdx.z * blockDim.z + threadIdx.z;

    const int32_t res_x = density_grid.size(0),
                  res_y = density_grid.size(1),
                  res_z = density_grid.size(2);
    // const int32_t res_x = resolution[0], res_y = resolution[1], res_z = resolution[2];
    if (x >= res_x || y >= res_y || z >= res_z) { return; }

    // traverse throught x-y-z axis
    const float density_self = density_grid[x][y][z];
    const bool inside = density_self > thresh;

    // ** vertices
    // x-axis
    if (x < res_x - 1) {
        const float density_x_next = density_grid[x + 1][y][z];
        const bool inside_x_next = (density_x_next > thresh);
        if (inside != inside_x_next) {
            int32_t vidx = atomicAdd(counters, 1);
            const float dt = (thresh - density_self) / (density_x_next - density_self);
            vertex_grid[x][y][z][0] = vidx + 1;
            vertices[vidx][0] = static_cast<float>(x) + dt;
            vertices[vidx][1] = static_cast<float>(y);
            vertices[vidx][2] = static_cast<float>(z);
        }
    }
    // y-axis
    if (y < res_y - 1) {
        const float density_y_next = density_grid[x][y + 1][z];
        const bool inside_y_next = (density_y_next > thresh);
        if (inside != inside_y_next) {
            int32_t vidx = atomicAdd(counters, 1);
            const float dt = (thresh - density_self) / (density_y_next - density_self);
            vertex_grid[x][y][z][1] = vidx + 1;
            vertices[vidx][0] = static_cast<float>(x);
            vertices[vidx][1] = static_cast<float>(y) + dt;
            vertices[vidx][2] = static_cast<float>(z);
        }
    }
    // z-axis
    if (z < res_z - 1) {
        const float density_z_next = density_grid[x][y][z + 1];
        const bool inside_z_next = (density_z_next > thresh);
        if (inside != inside_z_next) {
            int32_t vidx = atomicAdd(counters, 1);
            const float dt = (thresh - density_self) / (density_z_next - density_self);
            vertex_grid[x][y][z][2] = vidx + 1;
            vertices[vidx][0] = static_cast<float>(x);
            vertices[vidx][1] = static_cast<float>(y);
            vertices[vidx][2] = static_cast<float>(z) + dt;
        }
    }
}


__global__ void gen_faces_kernel(
    const torch::PackedTensorAccessor32<float, 3, torch::RestrictPtrTraits> density_grid,
    const float thresh,
    // output
    torch::PackedTensorAccessor32<int32_t, 4, torch::RestrictPtrTraits> vertex_grid,
    int32_t* __restrict__ faces,
    int32_t* __restrict__ counters
) {
	const int32_t x = blockIdx.x * blockDim.x + threadIdx.x;
	const int32_t y = blockIdx.y * blockDim.y + threadIdx.y;
	const int32_t z = blockIdx.z * blockDim.z + threadIdx.z;

    const int32_t res_x = density_grid.size(0),
                  res_y = density_grid.size(1),
                  res_z = density_grid.size(2);
    if (x >= res_x - 1 || y >= res_y - 1 || z >= res_z - 1) { return; }

    // traverse throught x-y-z axis
    const float density_self = density_grid[x][y][z];
    const bool inside = density_self > thresh;

    uint8_t mask = 0;
    if (density_grid[x][y][z]             > thresh) { mask |= 1; }
    if (density_grid[x + 1][y][z]         > thresh) { mask |= 2; }
    if (density_grid[x + 1][y + 1][z]     > thresh) { mask |= 4; }
    if (density_grid[x][y + 1][z]         > thresh) { mask |= 8; }
    if (density_grid[x][y][z + 1]         > thresh) { mask |= 16; }
    if (density_grid[x + 1][y][z + 1]     > thresh) { mask |= 32; }
    if (density_grid[x + 1][y + 1][z + 1] > thresh) { mask |= 64; }
    if (density_grid[x][y + 1][z + 1]     > thresh) { mask |= 128; }

    int32_t local_edges[12];
    local_edges[0] = vertex_grid[x][y][z][0];
    local_edges[1] = vertex_grid[x + 1][y][z][1];
    local_edges[2] = vertex_grid[x][y + 1][z][0];
    local_edges[3] = vertex_grid[x][y][z][1];

    local_edges[4] = vertex_grid[x][y][z + 1][0];
    local_edges[5] = vertex_grid[x + 1][y][z + 1][1];
    local_edges[6] = vertex_grid[x][y + 1][z + 1][0];
    local_edges[7] = vertex_grid[x][y][z + 1][1];

    local_edges[8] = vertex_grid[x][y][z][2];
    local_edges[9] = vertex_grid[x + 1][y][z][2];
    local_edges[10] = vertex_grid[x + 1][y + 1][z][2];
    local_edges[11] = vertex_grid[x][y + 1][z][2];
    
    int32_t tricount = 0; // init outside for atomicAdd
    const int8_t *triangles = triangle_table[mask];
    for (; tricount < 15; tricount += 3) {
        if (triangles[tricount] < 0) { break; }
    }
    int32_t tidx = atomicAdd(counters + 1, tricount);

    for (int32_t i = 0; i < 15; ++i) {
        int32_t j = triangles[i];
        if (j < 0) { break; }
        if (!local_edges[j]) {
            printf("at %d %d %d, mask is %d, j is %d, local_edges is 0\n", x, y, z, mask, j);
        }
        faces[tidx + i] = local_edges[j] - 1;
    }
}

std::vector<torch::Tensor> marching_cubes_wrapper(
    const torch::Tensor& density_grid,
    const float thresh,
    const bool verbose
) {
    const torch::Device curr_device = density_grid.device();
    const int32_t resolution[3] = {
        static_cast<int32_t>(density_grid.size(0)),
        static_cast<int32_t>(density_grid.size(1)),
        static_cast<int32_t>(density_grid.size(2))};
    torch::Tensor counters = torch::zeros({4},
        torch::TensorOptions().dtype(torch::kInt).device(curr_device));

    // init for parallel
    const uint32_t threads_x = 4, threads_y = 4, threads_z = 4;
    const dim3 threads = {threads_x, threads_y, threads_z};
    const uint32_t blocks_x = div_round_up(static_cast<uint32_t>(resolution[0]), threads_x),
                   blocks_y = div_round_up(static_cast<uint32_t>(resolution[1]), threads_y),
                   blocks_z = div_round_up(static_cast<uint32_t>(resolution[2]), threads_z);
    const dim3 blocks = {blocks_x, blocks_y, blocks_z};

    // count only
	count_vertices_faces_kernel<<<blocks, threads>>>(
        density_grid.packed_accessor32<float, 3, torch::RestrictPtrTraits>(),
        thresh,
        // output
        counters.data_ptr<int32_t>());
    
    const int32_t num_vertices = counters[0].item<int32_t>();
    const int32_t num_faces = counters[1].item<int32_t>() / 3;

    if (verbose) {
        printf("vertices: #vertices=%d\n", num_vertices);
        printf("faces: #triangles=%d\n", num_faces);
    }

    // init the essential tensor(memory space)
    torch::Tensor vertex_grid = torch::zeros({resolution[0], resolution[1], resolution[2], 3},
        torch::TensorOptions().dtype(torch::kInt).device(curr_device));
    torch::Tensor vertices = torch::zeros({num_vertices, 3},
        torch::TensorOptions().dtype(torch::kFloat).device(curr_device));
    torch::Tensor faces = torch::zeros({num_faces, 3},
        torch::TensorOptions().dtype(torch::kInt).device(curr_device));
    
    // generate vertices
    gen_vertices_kernel<<<blocks, threads>>>(
        density_grid.packed_accessor32<float, 3, torch::RestrictPtrTraits>(),
        thresh,
        // output
        vertex_grid.packed_accessor32<int32_t, 4, torch::RestrictPtrTraits>(),
        vertices.packed_accessor32<float, 2, torch::RestrictPtrTraits>(),
        counters.data_ptr<int32_t>() + 2);
    
    // generate faces
    gen_faces_kernel<<<blocks, threads>>>(
        density_grid.packed_accessor32<float, 3, torch::RestrictPtrTraits>(),
        thresh,
        // output
        vertex_grid.packed_accessor32<int32_t, 4, torch::RestrictPtrTraits>(),
        faces.data_ptr<int32_t>(),
        counters.data_ptr<int32_t>() + 2);

    std::vector<torch::Tensor> results(2);
    results[0] = vertices;
    results[1] = faces;
    
    return results;
}

void save_mesh_wrapper(
    const std::string filename,
    torch::Tensor vertices,
    torch::Tensor faces
) {
    torch::Tensor colors = torch::ones_like(vertices) * 0.5;

    std::ofstream ply_file(filename, std::ios::out | std::ios::binary);
    ply_file << "ply\n";
    ply_file << "format binary_little_endian 1.0\n";
    ply_file << "element vertex " << vertices.size(0) << std::endl;
    ply_file << "property float x\n";
    ply_file << "property float y\n";
    ply_file << "property float z\n";
    ply_file << "property float red\n";
    ply_file << "property float blue\n";
    ply_file << "property float green\n";
    ply_file << "element face " << faces.size(0) << std::endl;
    ply_file << "property list int int vertex_index\n";

    ply_file << "end_header\n";

    const int32_t num_vertices = vertices.size(0), num_faces = faces.size(0);

    torch::Tensor vertices_colors = torch::cat({vertices, colors}, 1); // [num_vertices, 4]
    const float* vertices_colors_ptr = vertices_colors.data_ptr<float>();
    ply_file.write((char *)&(vertices_colors_ptr[0]), num_vertices * 6 * sizeof(float));

    torch::Tensor faces_head = torch::ones({num_faces, 1},
        torch::TensorOptions().dtype(torch::kInt).device(torch::kCPU)) * 3;
    
    torch::Tensor padded_faces = torch::cat({faces_head, faces}, 1); // [num_faces, 4]
    CHECK_CONTIGUOUS(padded_faces);
    
    const int32_t* faces_ptr = padded_faces.data_ptr<int32_t>();
    ply_file.write((char *)&(faces_ptr[0]), num_faces * 4 * sizeof(int32_t));

    ply_file.close();
}

