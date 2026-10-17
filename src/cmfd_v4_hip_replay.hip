#include <hip/hip_runtime.h>
#define ROCBLAS_BETA_FEATURES_API
#include <rocblas/rocblas.h>

#include "cmfd_hip_discovery.hpp"
#include "cmfd_hip_worker_protocol.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace cmfd_hip {

constexpr uint32_t kFieldPrime = 0x7f000001U;
constexpr uint32_t kDimension = 4096;
constexpr uint32_t kRows = 128;
constexpr uint32_t kLayers = 384;
constexpr uint32_t kCoefficientsPerStage = 20;
constexpr uint32_t kStages = kLayers + 1;
constexpr uint64_t kBaseElements = uint64_t{kRows} * kDimension;
constexpr uint64_t kLayerElements = uint64_t{kDimension} * kDimension;
constexpr uint64_t kPayloadBytes = kBaseElements + uint64_t{kLayers} * kLayerElements;
constexpr int64_t kDigitBias = 128LL * (1LL + 256LL + 65536LL + 16777216LL);
constexpr int64_t kMaximumReconstructedMagnitude =
    int64_t{kDimension} * 128 * 125 * (1LL + 256LL + 65536LL + 16777216LL) +
    int64_t{kDimension} * 125 * kDigitBias;
static_assert(kMaximumReconstructedMagnitude < (1LL << 51));

[[noreturn]] void fail(const std::string& message) { throw std::runtime_error(message); }

void hip_check(hipError_t status, const char* operation) {
    if (status != hipSuccess) {
        fail(std::string(operation) + ": " + hipGetErrorString(status));
    }
}

void rocblas_check(rocblas_status status, const char* operation) {
    if (status != rocblas_status_success) {
        fail(std::string(operation) + ": rocBLAS status " + std::to_string(static_cast<int>(status)));
    }
}

template <typename T>
class DeviceBuffer {
  public:
    DeviceBuffer() = default;
    explicit DeviceBuffer(uint64_t count) { allocate(count); }
    ~DeviceBuffer() { reset(); }
    DeviceBuffer(const DeviceBuffer&) = delete;
    DeviceBuffer& operator=(const DeviceBuffer&) = delete;
    DeviceBuffer(DeviceBuffer&& other) noexcept { swap(other); }
    DeviceBuffer& operator=(DeviceBuffer&& other) noexcept {
        if (this != &other) {
            reset();
            swap(other);
        }
        return *this;
    }
    void allocate(uint64_t count) {
        reset();
        if (count > std::numeric_limits<size_t>::max() / sizeof(T)) fail("device allocation is too large");
        count_ = count;
        hip_check(hipMalloc(reinterpret_cast<void**>(&data_), static_cast<size_t>(count * sizeof(T))), "hipMalloc");
    }
    void reset() {
        if (data_) (void)hipFree(data_);
        data_ = nullptr;
        count_ = 0;
    }
    T* get() const { return data_; }
    uint64_t size() const { return count_; }

  private:
    void swap(DeviceBuffer& other) noexcept {
        std::swap(data_, other.data_);
        std::swap(count_, other.count_);
    }
    T* data_ = nullptr;
    uint64_t count_ = 0;
};

template <typename T>
class PinnedBuffer {
  public:
    PinnedBuffer() = default;
    explicit PinnedBuffer(uint64_t count) { allocate(count); }
    ~PinnedBuffer() { reset(); }
    PinnedBuffer(const PinnedBuffer&) = delete;
    PinnedBuffer& operator=(const PinnedBuffer&) = delete;
    void allocate(uint64_t count) {
        reset();
        if (count > std::numeric_limits<size_t>::max() / sizeof(T)) fail("pinned allocation is too large");
        count_ = count;
        hip_check(hipHostMalloc(reinterpret_cast<void**>(&data_),
                                static_cast<size_t>(count * sizeof(T)), hipHostMallocDefault),
                  "hipHostMalloc");
    }
    void reset() {
        if (data_) (void)hipHostFree(data_);
        data_ = nullptr;
        count_ = 0;
    }
    T* get() const { return data_; }
    uint64_t size() const { return count_; }

  private:
    T* data_ = nullptr;
    uint64_t count_ = 0;
};

#pragma pack(push, 1)
struct BankHeader {
    char magic[8];
    uint32_t format_version;
    uint32_t header_bytes;
    uint32_t model_version;
    uint32_t dimension;
    uint32_t batch;
    uint32_t layers;
    uint64_t base_input_bytes;
    uint64_t bytes_per_layer;
    uint64_t payload_bytes;
    uint8_t digests[128];
};
#pragma pack(pop)
static_assert(sizeof(BankHeader) == 184);

__device__ __forceinline__ uint32_t field_from_signed(int32_t value) {
    return value < 0 ? static_cast<uint32_t>(static_cast<int64_t>(value) + kFieldPrime)
                     : static_cast<uint32_t>(value);
}

__device__ __forceinline__ uint32_t field_reduce_signed(int64_t value) {
    // p = 2^31 - 2^24 + 1, hence 2^31 == 2^24 - 1 (mod p).
    // ProductionV4's exact accumulator bound is below 2^51, so four fixed
    // folds leave a value below 2p and one conditional subtraction is enough.
    const bool negative = value < 0;
    uint64_t magnitude = negative
        ? static_cast<uint64_t>(-(value + 1)) + 1
        : static_cast<uint64_t>(value);
#pragma unroll
    for (uint32_t fold = 0; fold < 4; ++fold)
        magnitude = (magnitude & 0x7fffffffULL) + (magnitude >> 31) * 0x00ffffffULL;
    uint32_t reduced = static_cast<uint32_t>(magnitude);
    if (reduced >= kFieldPrime) reduced -= kFieldPrime;
    if (negative && reduced != 0) reduced = kFieldPrime - reduced;
    return reduced;
}

__device__ __forceinline__ uint32_t field_mul(uint32_t lhs, uint32_t rhs) {
    return static_cast<uint32_t>((static_cast<uint64_t>(lhs) * rhs) % kFieldPrime);
}

__device__ __forceinline__ uint32_t field_cube(uint32_t value) {
    return field_mul(field_mul(value, value), value);
}

__device__ __forceinline__ uint32_t coordinate_mask(
    const uint8_t* coefficients, uint32_t row, uint32_t column, uint32_t row_bits, uint32_t column_bits) {
    // Coefficients originate from canonical bytes.  At most 20 values are
    // accumulated, so the sum is <= 5100 and cannot reach the field modulus.
    uint32_t result = coefficients[0];
    for (uint32_t bit = 0; bit < row_bits; ++bit) {
        if ((row >> bit) & 1U) result += coefficients[1 + bit];
    }
    for (uint32_t bit = 0; bit < column_bits; ++bit) {
        if ((column >> bit) & 1U) result += coefficients[1 + row_bits + bit];
    }
    return result;
}

__global__ void transpose_center_kernel(const uint8_t* source, int8_t* destination, uint32_t width) {
    __shared__ int8_t tile[32][33];
    const uint32_t source_column = blockIdx.x * 32 + threadIdx.x;
    const uint32_t source_row_base = blockIdx.y * 32 + threadIdx.y;
    for (uint32_t offset = 0; offset < 32; offset += 8) {
        const uint32_t source_row = source_row_base + offset;
        if (source_column < width && source_row < width) {
            tile[threadIdx.y + offset][threadIdx.x] =
                static_cast<int8_t>(static_cast<int32_t>(source[uint64_t{source_row} * width + source_column]) - 125);
        }
    }
    __syncthreads();
    const uint32_t destination_column = blockIdx.y * 32 + threadIdx.x;
    const uint32_t destination_row_base = blockIdx.x * 32 + threadIdx.y;
    for (uint32_t offset = 0; offset < 32; offset += 8) {
        const uint32_t destination_row = destination_row_base + offset;
        if (destination_column < width && destination_row < width) {
            destination[uint64_t{destination_row} * width + destination_column] = tile[threadIdx.x][threadIdx.y + offset];
        }
    }
}

__global__ void weight_column_sums_kernel(
    const int8_t* transposed_weights, int64_t* biases, uint32_t width) {
    __shared__ int32_t partial[256];
    const uint32_t column = blockIdx.x;
    int32_t local = 0;
    if (column < width) {
        const int8_t* values = transposed_weights + uint64_t{column} * width;
        for (uint32_t k = threadIdx.x; k < width; k += blockDim.x) local += values[k];
    }
    partial[threadIdx.x] = local;
    __syncthreads();
    for (uint32_t stride = blockDim.x / 2; stride; stride >>= 1) {
        if (threadIdx.x < stride) partial[threadIdx.x] += partial[threadIdx.x + stride];
        __syncthreads();
    }
    if (threadIdx.x == 0 && column < width)
        biases[column] = static_cast<int64_t>(partial[0]) * kDigitBias;
}

__global__ void precompute_coordinate_masks_kernel(const uint8_t* coefficients,
                                                    uint16_t* row_masks,
                                                    uint16_t* column_masks,
                                                    uint32_t rows,
                                                    uint32_t width,
                                                    uint32_t nonce_count) {
    const uint64_t coordinates_per_stage = uint64_t{rows} + width;
    const uint64_t entry = uint64_t{blockIdx.x} * blockDim.x + threadIdx.x;
    const uint64_t entry_count = uint64_t{nonce_count} * kStages * coordinates_per_stage;
    if (entry >= entry_count) return;
    const uint64_t stage = entry / coordinates_per_stage;
    const uint32_t coordinate = static_cast<uint32_t>(entry - stage * coordinates_per_stage);
    const uint8_t* stage_coefficients = coefficients + stage * kCoefficientsPerStage;
    if (coordinate < rows) {
        uint32_t mask = stage_coefficients[0];
        const uint32_t row_bits = __ffs(rows) - 1;
        for (uint32_t bit = 0; bit < row_bits; ++bit)
            if ((coordinate >> bit) & 1U) mask += stage_coefficients[1 + bit];
        row_masks[stage * rows + coordinate] = static_cast<uint16_t>(mask);
    } else {
        const uint32_t column = coordinate - rows;
        const uint32_t row_bits = __ffs(rows) - 1;
        const uint32_t column_bits = __ffs(width) - 1;
        uint32_t mask = 0;
        for (uint32_t bit = 0; bit < column_bits; ++bit)
            if ((column >> bit) & 1U) mask += stage_coefficients[1 + row_bits + bit];
        column_masks[stage * width + column] = static_cast<uint16_t>(mask);
    }
}

__global__ void initialize_activation_kernel(const int8_t* base,
                                             int8_t* limbs,
                                             uint32_t* activations,
                                             const uint8_t* coefficients,
                                             const uint16_t* row_masks,
                                             const uint16_t* column_masks,
                                             uint32_t rows,
                                             uint32_t width,
                                             uint32_t nonce_count) {
    const uint64_t index = uint64_t{blockIdx.x} * blockDim.x + threadIdx.x;
    const uint64_t plane = uint64_t{rows} * width;
    if (index >= plane * nonce_count) return;
    const uint32_t nonce = static_cast<uint32_t>(index / plane);
    const uint64_t within = index - uint64_t{nonce} * plane;
    const uint32_t row = static_cast<uint32_t>(within / width);
    const uint32_t column = static_cast<uint32_t>(within - uint64_t{row} * width);
    const uint32_t row_bits = __ffs(rows) - 1;
    const uint32_t column_bits = __ffs(width) - 1;
    const uint8_t* stage_coefficients = coefficients + uint64_t{nonce} * kStages * kCoefficientsPerStage;
    const uint64_t stage = uint64_t{nonce} * kStages;
    const uint32_t mask = row_masks
        ? static_cast<uint32_t>(row_masks[stage * rows + row]) +
              static_cast<uint32_t>(column_masks[stage * width + column])
        : coordinate_mask(stage_coefficients, row, column, row_bits, column_bits);
    uint32_t value = field_from_signed(base[within]);
    value += mask;
    if (value >= kFieldPrime) value -= kFieldPrime;
    value = field_cube(value);
    if (activations) activations[index] = value;
    const uint64_t limb_base = uint64_t{nonce} * 4 * plane + within;
    limbs[limb_base] = static_cast<int8_t>((value & 0xffU) ^ 0x80U);
    limbs[limb_base + plane] = static_cast<int8_t>(((value >> 8) & 0xffU) ^ 0x80U);
    limbs[limb_base + 2 * plane] = static_cast<int8_t>(((value >> 16) & 0xffU) ^ 0x80U);
    limbs[limb_base + 3 * plane] = static_cast<int8_t>(((value >> 24) & 0xffU) | 0x80U);
}

__global__ void reduce_layer_kernel(const int32_t* accumulators,
                                    int8_t* limbs,
                                    uint32_t* preactivations,
                                    uint32_t* activations,
                                    const uint8_t* coefficients,
                                    const uint16_t* row_masks,
                                    const uint16_t* column_masks,
                                    const int64_t* weight_biases,
                                    uint32_t layer,
                                    uint32_t rows,
                                    uint32_t width,
                                    uint32_t nonce_count) {
    const uint64_t index = uint64_t{blockIdx.x} * blockDim.x + threadIdx.x;
    const uint64_t plane = uint64_t{rows} * width;
    if (index >= plane * nonce_count) return;
    const uint32_t nonce = static_cast<uint32_t>(index / plane);
    const uint64_t within = index - uint64_t{nonce} * plane;
    const uint32_t row = static_cast<uint32_t>(within / width);
    const uint32_t column = static_cast<uint32_t>(within - uint64_t{row} * width);
    const uint64_t accumulator_base = uint64_t{nonce} * 4 * plane + within;
    const int64_t reconstructed =
        static_cast<int64_t>(accumulators[accumulator_base]) +
        static_cast<int64_t>(accumulators[accumulator_base + plane]) * 256LL +
        static_cast<int64_t>(accumulators[accumulator_base + 2 * plane]) * 65536LL +
        static_cast<int64_t>(accumulators[accumulator_base + 3 * plane]) * 16777216LL +
        weight_biases[column];
    const uint32_t row_bits = __ffs(rows) - 1;
    const uint32_t column_bits = __ffs(width) - 1;
    const uint8_t* stage_coefficients = coefficients +
        (uint64_t{nonce} * kStages + layer + 1) * kCoefficientsPerStage;
    const uint64_t stage = uint64_t{nonce} * kStages + layer + 1;
    const uint32_t mask = row_masks
        ? static_cast<uint32_t>(row_masks[stage * rows + row]) +
              static_cast<uint32_t>(column_masks[stage * width + column])
        : coordinate_mask(stage_coefficients, row, column, row_bits, column_bits);
    uint32_t preactivation = field_reduce_signed(reconstructed);
    preactivation += mask;
    if (preactivation >= kFieldPrime) preactivation -= kFieldPrime;
    if (preactivations) preactivations[index] = preactivation;
    const uint32_t value = field_cube(preactivation);
    if (activations) activations[index] = value;
    const uint64_t limb_base = uint64_t{nonce} * 4 * plane + within;
    limbs[limb_base] = static_cast<int8_t>((value & 0xffU) ^ 0x80U);
    limbs[limb_base + plane] = static_cast<int8_t>(((value >> 8) & 0xffU) ^ 0x80U);
    limbs[limb_base + 2 * plane] = static_cast<int8_t>(((value >> 16) & 0xffU) ^ 0x80U);
    limbs[limb_base + 3 * plane] = static_cast<int8_t>(((value >> 24) & 0xffU) | 0x80U);
}

__global__ void field_reduce_self_test_kernel(
    const int64_t* inputs, uint32_t* outputs, uint32_t count) {
    const uint32_t index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < count) outputs[index] = field_reduce_signed(inputs[index]);
}

__global__ void field_cube_self_test_kernel(
    const uint32_t* inputs, uint32_t* outputs, uint32_t count) {
    const uint32_t index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < count) outputs[index] = field_cube(inputs[index]);
}

uint32_t cpu_field_reduce_signed(int64_t value) {
    int64_t result = value % static_cast<int64_t>(kFieldPrime);
    if (result < 0) result += kFieldPrime;
    return static_cast<uint32_t>(result);
}

uint32_t cpu_field_cube(uint32_t value) {
    const uint32_t square = static_cast<uint32_t>((static_cast<uint64_t>(value) * value) % kFieldPrime);
    return static_cast<uint32_t>((static_cast<uint64_t>(square) * value) % kFieldPrime);
}

uint32_t cpu_mask(const uint8_t* coefficients,
                  uint32_t row,
                  uint32_t column,
                  uint32_t row_bits,
                  uint32_t column_bits) {
    uint32_t result = coefficients[0];
    for (uint32_t bit = 0; bit < row_bits; ++bit)
        if ((row >> bit) & 1U) result += coefficients[1 + bit];
    for (uint32_t bit = 0; bit < column_bits; ++bit)
        if ((column >> bit) & 1U) result += coefficients[1 + row_bits + bit];
    return result;
}

class ProductionModel {
  public:
    explicit ProductionModel(std::string path) : path_(std::move(path)) {}

    void load() {
        if (loaded_) return;
        std::ifstream input(path_, std::ios::binary | std::ios::ate);
        if (!input) fail("cannot open ProductionV4 bank: " + path_);
        const uint64_t size = static_cast<uint64_t>(input.tellg());
        input.seekg(0);
        BankHeader header{};
        input.read(reinterpret_cast<char*>(&header), sizeof(header));
        if (!input) fail("cannot read ProductionV4 bank header");
        const std::array<char, 8> expected_magic{'C', 'M', 'F', 'D', 'B', 'N', 'K', '2'};
        if (std::memcmp(header.magic, expected_magic.data(), expected_magic.size()) != 0 ||
            header.format_version != 2 || header.header_bytes != sizeof(BankHeader) ||
            header.model_version != 2 || header.dimension != kDimension || header.batch != kRows ||
            header.layers != kLayers || header.base_input_bytes != kBaseElements ||
            header.bytes_per_layer != kLayerElements || header.payload_bytes != kPayloadBytes ||
            size != sizeof(BankHeader) + kPayloadBytes) {
            fail("ProductionV4 bank geometry/header mismatch");
        }

        auto start = std::chrono::steady_clock::now();
        weights_.allocate(uint64_t{kLayers} * kLayerElements);
        base_.allocate(kBaseElements);
        weight_biases_.allocate(uint64_t{kLayers} * kDimension);
        DeviceBuffer<uint8_t> staging(kLayerElements);

        std::vector<uint8_t> base_raw(kBaseElements);
        std::vector<int8_t> base_centered(kBaseElements);
        input.read(reinterpret_cast<char*>(base_raw.data()), static_cast<std::streamsize>(base_raw.size()));
        if (!input) fail("cannot read ProductionV4 base input");
        std::transform(base_raw.begin(), base_raw.end(), base_centered.begin(), [](uint8_t value) {
            return static_cast<int8_t>(static_cast<int32_t>(value) - 125);
        });
        hip_check(hipMemcpy(base_.get(), base_centered.data(), base_centered.size(), hipMemcpyHostToDevice),
                  "copy ProductionV4 base input");

        uint8_t* pinned_layer = nullptr;
        hip_check(hipHostMalloc(reinterpret_cast<void**>(&pinned_layer), kLayerElements), "allocate pinned layer staging");
        std::unique_ptr<uint8_t, decltype(&hipHostFree)> pinned_guard(pinned_layer, hipHostFree);
        const dim3 transpose_block(32, 8);
        const dim3 transpose_grid((kDimension + 31) / 32, (kDimension + 31) / 32);
        for (uint32_t layer = 0; layer < kLayers; ++layer) {
            input.read(reinterpret_cast<char*>(pinned_layer), static_cast<std::streamsize>(kLayerElements));
            if (!input) fail("cannot read ProductionV4 weight layer " + std::to_string(layer));
            hip_check(hipMemcpy(staging.get(), pinned_layer, kLayerElements, hipMemcpyHostToDevice),
                      "copy canonical ProductionV4 weight layer");
            int8_t* layer_weights = weights_.get() + uint64_t{layer} * kLayerElements;
            hipLaunchKernelGGL(transpose_center_kernel,
                               transpose_grid,
                               transpose_block,
                               0,
                               0,
                               staging.get(),
                               layer_weights,
                               kDimension);
            hip_check(hipGetLastError(), "transpose ProductionV4 weight layer");
            hipLaunchKernelGGL(weight_column_sums_kernel,
                               dim3(kDimension),
                               dim3(256),
                               0,
                               0,
                               layer_weights,
                               weight_biases_.get() + uint64_t{layer} * kDimension,
                               kDimension);
            hip_check(hipGetLastError(), "calculate ProductionV4 weight sums");
            if ((layer + 1) % 32 == 0 || layer + 1 == kLayers) {
                hip_check(hipDeviceSynchronize(), "finish ProductionV4 model load batch");
                std::cerr << "CMFD_HIP_LOAD layers=" << (layer + 1) << "/" << kLayers << '\n';
            }
        }
        loaded_ = true;
        const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        std::cerr << std::fixed << std::setprecision(3) << "CMFD_HIP_MODEL_READY seconds=" << seconds
                  << " weights_bytes=" << uint64_t{kLayers} * kLayerElements << '\n';
    }

    void evict() {
        weights_.reset();
        base_.reset();
        weight_biases_.reset();
        loaded_ = false;
    }

    bool loaded() const { return loaded_; }
    const int8_t* weights(uint32_t layer) const { return weights_.get() + uint64_t{layer} * kLayerElements; }
    const int8_t* base() const { return base_.get(); }
    const int64_t* weight_biases(uint32_t layer) const {
        return weight_biases_.get() + uint64_t{layer} * kDimension;
    }

  private:
    std::string path_;
    DeviceBuffer<int8_t> weights_;
    DeviceBuffer<int8_t> base_;
    DeviceBuffer<int64_t> weight_biases_;
    bool loaded_ = false;
};

std::vector<uint8_t> load_coefficients(const std::string& path, uint32_t nonce_count) {
    const uint64_t byte_count = uint64_t{nonce_count} * kStages * kCoefficientsPerStage;
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input) fail("cannot open replay coefficients: " + path);
    if (static_cast<uint64_t>(input.tellg()) != byte_count) fail("replay coefficient file has the wrong byte length");
    input.seekg(0);
    std::vector<uint8_t> coefficients(byte_count);
    input.read(reinterpret_cast<char*>(coefficients.data()), static_cast<std::streamsize>(coefficients.size()));
    if (!input) fail("cannot read replay coefficients");
    return coefficients;
}

class ReplayEngine {
  public:
    static constexpr int32_t kAutoSolution = std::numeric_limits<int32_t>::max();

    explicit ReplayEngine(ProductionModel& model,
                          std::string architecture,
                          int32_t configured_solution = kAutoSolution,
                          bool use_graph = true,
                          uint32_t workgroup_size = 512,
                          bool precompute_masks = true)
        : model_(model), architecture_(std::move(architecture)),
          configured_solution_(configured_solution), use_graph_(use_graph),
          workgroup_size_(workgroup_size), precompute_masks_(precompute_masks) {
        if (workgroup_size_ < 64 || workgroup_size_ > 1024 || (workgroup_size_ & (workgroup_size_ - 1)))
            fail("workgroup size must be a power of two from 64 through 1024");
        hip_check(hipStreamCreateWithFlags(&stream_, hipStreamNonBlocking), "hipStreamCreateWithFlags");
        rocblas_check(rocblas_create_handle(&blas_), "rocblas_create_handle");
        rocblas_check(rocblas_set_stream(blas_, stream_), "rocblas_set_stream");
    }
    ~ReplayEngine() {
        workspace_.reset();
        if (blas_) rocblas_destroy_handle(blas_);
        if (stream_) (void)hipStreamDestroy(stream_);
    }
    ReplayEngine(const ReplayEngine&) = delete;
    ReplayEngine& operator=(const ReplayEngine&) = delete;

    void reset_workspace() { workspace_.reset(); }

    double run_batch(uint32_t nonce_count, const std::string& coefficient_path, const std::string& output_path) {
        if (nonce_count < 1 || nonce_count > 64) fail("search batch count must be from 1 through 64");
        model_.load();
        const auto wall_start = std::chrono::steady_clock::now();
        const auto host_coefficients = load_coefficients(coefficient_path, nonce_count);
        ensure_workspace(nonce_count, host_coefficients.size());
        Workspace& workspace = *workspace_;
        hip_check(hipMemcpyAsync(workspace.coefficients.get(),
                                 host_coefficients.data(),
                                 host_coefficients.size(),
                                 hipMemcpyHostToDevice,
                                 stream_),
                  "copy replay coefficients");

        hipEvent_t start_event = nullptr;
        hipEvent_t stop_event = nullptr;
        hip_check(hipEventCreate(&start_event), "create replay start event");
        hip_check(hipEventCreate(&stop_event), "create replay stop event");
        hip_check(hipEventRecord(start_event, stream_), "record replay start event");
        if (use_graph_) {
            hip_check(hipGraphLaunch(workspace.graph_exec, stream_), "launch ProductionV4 HIP graph");
        } else {
            record_work(workspace);
        }
        hip_check(hipEventRecord(stop_event, stream_), "record replay stop event");
        hip_check(hipEventSynchronize(stop_event), "finish ProductionV4 search batch");
        float milliseconds = 0.0F;
        hip_check(hipEventElapsedTime(&milliseconds, start_event, stop_event), "measure ProductionV4 search batch");
        hip_check(hipEventDestroy(stop_event), "destroy replay stop event");
        hip_check(hipEventDestroy(start_event), "destroy replay start event");

        const auto copy_start = std::chrono::steady_clock::now();
        uint32_t* result = workspace.host_activations.get();
        hip_check(hipMemcpyAsync(result,
                                 workspace.activations.get(),
                                 workspace.activation_elements * sizeof(uint32_t),
                                 hipMemcpyDeviceToHost,
                                 stream_),
                  "copy final ProductionV4 activations");
        hip_check(hipStreamSynchronize(stream_), "finish final ProductionV4 activation copy");
        const auto validation_start = std::chrono::steady_clock::now();
        for (uint64_t index = 0; index < workspace.activation_elements; ++index)
            if (result[index] >= kFieldPrime)
                fail("ProductionV4 replay emitted a noncanonical field value");
        const auto write_start = std::chrono::steady_clock::now();
        const fs::path output_fs(output_path + "-final-activation.bin");
        if (!output_fs.parent_path().empty()) fs::create_directories(output_fs.parent_path());
        std::ofstream output(output_fs, std::ios::binary | std::ios::trunc);
        if (!output) fail("cannot create final activation output: " + output_path);
        output.write(reinterpret_cast<const char*>(result),
                     static_cast<std::streamsize>(workspace.activation_elements * sizeof(uint32_t)));
        if (!output) fail("cannot write final activation output");
        output.flush();
        if (!output) fail("cannot flush final activation output");
        const auto output_done = std::chrono::steady_clock::now();
        const double seconds = milliseconds / 1000.0;
        const double wall_seconds =
            std::chrono::duration<double>(std::chrono::steady_clock::now() - wall_start).count();
        std::cerr << std::fixed << std::setprecision(6) << "CMFD_HIP_REPLAY mode=search_batch nonces="
                  << nonce_count << " seconds=" << seconds << " fw_per_second=" << nonce_count / seconds
                  << " wall_seconds=" << wall_seconds
                  << " effective_fw_per_second=" << nonce_count / wall_seconds
                  << " graph=" << (use_graph_ ? "on" : "off") << " solution=" << workspace.solution << '\n';
        std::cerr << "CMFD_HIP_OUTPUT copy_seconds="
                  << std::chrono::duration<double>(validation_start - copy_start).count()
                  << " validation_seconds="
                  << std::chrono::duration<double>(write_start - validation_start).count()
                  << " write_seconds="
                  << std::chrono::duration<double>(output_done - write_start).count() << '\n';
        return seconds;
    }

  private:
    struct Workspace {
        ~Workspace() {
            if (graph_exec) (void)hipGraphExecDestroy(graph_exec);
            if (graph) (void)hipGraphDestroy(graph);
        }
        uint32_t nonce_count = 0;
        uint64_t activation_elements = 0;
        int32_t solution = 0;
        DeviceBuffer<int8_t> limbs;
        DeviceBuffer<int32_t> accumulators;
        DeviceBuffer<uint32_t> activations;
        DeviceBuffer<uint8_t> coefficients;
        DeviceBuffer<uint16_t> row_masks;
        DeviceBuffer<uint16_t> column_masks;
        PinnedBuffer<uint32_t> host_activations;
        hipGraph_t graph = nullptr;
        hipGraphExec_t graph_exec = nullptr;
    };

    int32_t configured_solution(uint32_t nonce_count) const {
        if (configured_solution_ != kAutoSolution) return configured_solution_;
        if (architecture_ != "gfx1100") return 0;
        if (nonce_count == 64) return -1140854992;
        if (nonce_count == 32) return -1140855025;
        if (nonce_count == 4) return -1140855021;
        return 0;
    }

    bool solution_available(Workspace& workspace, int32_t solution) {
        if (solution == 0) return true;
        constexpr int32_t alpha = 1;
        constexpr int32_t beta = 0;
        const rocblas_int m = static_cast<rocblas_int>(4U * kRows * workspace.nonce_count);
        rocblas_int count = 0;
        rocblas_check(rocblas_gemm_ex_get_solutions(blas_, rocblas_operation_transpose,
            rocblas_operation_none, kDimension, m, kDimension, &alpha, model_.weights(0),
            rocblas_datatype_i8_r, kDimension, workspace.limbs.get(), rocblas_datatype_i8_r,
            kDimension, &beta, workspace.accumulators.get(), rocblas_datatype_i32_r, kDimension,
            workspace.accumulators.get(), rocblas_datatype_i32_r, kDimension, rocblas_datatype_i32_r,
            rocblas_gemm_algo_standard, rocblas_gemm_flags_none, nullptr, &count),
            "query selected GEMM solution count");
        std::vector<rocblas_int> available(count);
        rocblas_check(rocblas_gemm_ex_get_solutions(blas_, rocblas_operation_transpose,
            rocblas_operation_none, kDimension, m, kDimension, &alpha, model_.weights(0),
            rocblas_datatype_i8_r, kDimension, workspace.limbs.get(), rocblas_datatype_i8_r,
            kDimension, &beta, workspace.accumulators.get(), rocblas_datatype_i32_r, kDimension,
            workspace.accumulators.get(), rocblas_datatype_i32_r, kDimension, rocblas_datatype_i32_r,
            rocblas_gemm_algo_standard, rocblas_gemm_flags_none, available.data(), &count),
            "query selected GEMM solutions");
        available.resize(count);
        return std::find(available.begin(), available.end(), solution) != available.end();
    }

    void launch_gemm(Workspace& workspace, uint32_t layer) {
        constexpr int32_t alpha = 1;
        constexpr int32_t beta = 0;
        const rocblas_int m = static_cast<rocblas_int>(4U * kRows * workspace.nonce_count);
        // rocBLAS is column-major. Compute C^T = W^T * A^T while retaining the
        // official CUTLASS row-major A/C and column-major W byte layout.
        rocblas_check(rocblas_gemm_ex(blas_, rocblas_operation_transpose, rocblas_operation_none,
            kDimension, m, kDimension, &alpha, model_.weights(layer), rocblas_datatype_i8_r,
            kDimension, workspace.limbs.get(), rocblas_datatype_i8_r, kDimension, &beta,
            workspace.accumulators.get(), rocblas_datatype_i32_r, kDimension,
            workspace.accumulators.get(), rocblas_datatype_i32_r, kDimension,
            rocblas_datatype_i32_r,
            workspace.solution == 0 ? rocblas_gemm_algo_standard : rocblas_gemm_algo_solution_index,
            workspace.solution, rocblas_gemm_flags_none), "ProductionV4 int8 GEMM");
    }

    void record_work(Workspace& workspace) {
        if (precompute_masks_) {
            const uint64_t mask_entries =
                uint64_t{workspace.nonce_count} * kStages * (kRows + kDimension);
            const uint32_t mask_blocks = static_cast<uint32_t>(
                (mask_entries + workgroup_size_ - 1) / workgroup_size_);
            hipLaunchKernelGGL(precompute_coordinate_masks_kernel,
                               dim3(mask_blocks), dim3(workgroup_size_), 0, stream_,
                               workspace.coefficients.get(), workspace.row_masks.get(),
                               workspace.column_masks.get(), kRows, kDimension,
                               workspace.nonce_count);
            hip_check(hipGetLastError(), "precompute ProductionV4 coordinate masks");
        }
        const uint32_t blocks = static_cast<uint32_t>(
            (workspace.activation_elements + workgroup_size_ - 1) / workgroup_size_);
        hipLaunchKernelGGL(initialize_activation_kernel, dim3(blocks), dim3(workgroup_size_), 0, stream_,
                           model_.base(), workspace.limbs.get(), nullptr,
                           workspace.coefficients.get(), workspace.row_masks.get(),
                           workspace.column_masks.get(), kRows, kDimension, workspace.nonce_count);
        hip_check(hipGetLastError(), "initialize ProductionV4 activations");
        for (uint32_t layer = 0; layer < kLayers; ++layer) {
            launch_gemm(workspace, layer);
            hipLaunchKernelGGL(reduce_layer_kernel, dim3(blocks), dim3(workgroup_size_), 0, stream_,
                               workspace.accumulators.get(), workspace.limbs.get(), nullptr,
                               layer + 1 == kLayers ? workspace.activations.get() : nullptr,
                               workspace.coefficients.get(), workspace.row_masks.get(),
                               workspace.column_masks.get(), model_.weight_biases(layer), layer,
                               kRows, kDimension, workspace.nonce_count);
            hip_check(hipGetLastError(), "reduce ProductionV4 layer");
        }
    }

    void ensure_workspace(uint32_t nonce_count, uint64_t coefficient_count) {
        if (workspace_ && workspace_->nonce_count == nonce_count) return;
        workspace_.reset();
        auto workspace = std::make_unique<Workspace>();
        workspace->nonce_count = nonce_count;
        workspace->activation_elements = uint64_t{nonce_count} * kBaseElements;
        const uint64_t limb_elements = 4 * workspace->activation_elements;
        workspace->limbs.allocate(limb_elements);
        workspace->accumulators.allocate(limb_elements);
        workspace->activations.allocate(workspace->activation_elements);
        workspace->host_activations.allocate(workspace->activation_elements);
        workspace->coefficients.allocate(coefficient_count);
        if (precompute_masks_) {
            workspace->row_masks.allocate(uint64_t{nonce_count} * kStages * kRows);
            workspace->column_masks.allocate(uint64_t{nonce_count} * kStages * kDimension);
        }
        workspace->solution = configured_solution(nonce_count);
        if (!solution_available(*workspace, workspace->solution)) {
            std::cerr << "CMFD_HIP_WARNING selected solution unavailable; using rocBLAS default\n";
            workspace->solution = 0;
        }

        // Prime rocBLAS outside capture so lazy library initialization is not inserted into the graph.
        launch_gemm(*workspace, 0);
        hip_check(hipStreamSynchronize(stream_), "warm up ProductionV4 GEMM");
        if (use_graph_) {
            const auto graph_start = std::chrono::steady_clock::now();
            hip_check(hipStreamBeginCapture(stream_, hipStreamCaptureModeGlobal), "begin ProductionV4 graph capture");
            record_work(*workspace);
            hip_check(hipStreamEndCapture(stream_, &workspace->graph), "end ProductionV4 graph capture");
            hip_check(hipGraphInstantiate(&workspace->graph_exec, workspace->graph, nullptr, nullptr, 0),
                      "instantiate ProductionV4 graph");
            const double setup_seconds =
                std::chrono::duration<double>(std::chrono::steady_clock::now() - graph_start).count();
            std::cerr << std::fixed << std::setprecision(6) << "CMFD_HIP_GRAPH_READY nonces=" << nonce_count
                      << " seconds=" << setup_seconds << " solution=" << workspace->solution << '\n';
        }
        size_t free_bytes = 0;
        size_t total_bytes = 0;
        hip_check(hipMemGetInfo(&free_bytes, &total_bytes), "query HIP workspace memory");
        std::cerr << "CMFD_HIP_WORKSPACE nonces=" << nonce_count
                  << " free_vram_bytes=" << free_bytes
                  << " used_vram_bytes=" << (total_bytes - free_bytes)
                  << " total_vram_bytes=" << total_bytes << '\n';
        workspace_ = std::move(workspace);
    }

    ProductionModel& model_;
    std::string architecture_;
    rocblas_handle blas_ = nullptr;
    hipStream_t stream_ = nullptr;
    int32_t configured_solution_ = kAutoSolution;
    bool use_graph_ = true;
    uint32_t workgroup_size_ = 512;
    bool precompute_masks_ = true;
    std::unique_ptr<Workspace> workspace_;
};

discovery::Device select_device(
    int requested_device, const std::optional<std::string>& requested_selector) {
    if (requested_device >= 0 && requested_selector)
        fail("--device and --device-selector are mutually exclusive");

    const discovery::RuntimeInfo runtime = discovery::inspect_runtime();
    const discovery::Inventory inventory = discovery::discover_devices(runtime);
    if (inventory.error) fail(inventory.error->code + ": " + inventory.error->message);

    std::optional<std::string> selector = requested_selector;
    if (!selector && requested_device >= 0) selector = "hip:" + std::to_string(requested_device);
    const discovery::Policy policy = discovery::policy_from_environment();
    const discovery::Selection selected =
        discovery::select_device(inventory.devices, selector, policy, runtime);
    if (selected.error) fail(selected.error->code + ": " + selected.error->message);
    if (!selected.device) fail("HIP discovery returned no selected device");

    hip_check(hipSetDevice(selected.device->hip_index), "hipSetDevice");
    std::cerr << "CMFD_HIP_DEVICE index=" << selected.device->hip_index
              << " selector=\"" << discovery::worker_selector(*selected.device)
              << "\" name=\"" << selected.device->name << "\" arch="
              << discovery::base_architecture(selected.device->architecture)
              << " vram_bytes=" << selected.device->vram_bytes
              << " integrated="
              << (!selected.device->integrated ? "unknown"
                  : *selected.device->integrated ? "yes" : "no")
              << " physically_tested="
              << (discovery::evaluate_device(*selected.device, policy, runtime).physically_tested
                      ? "yes" : "no")
              << " runtime_version=\"" << runtime.version << "\""
              << " runtime_root=\"" << runtime.root << "\""
              << '\n';
    return *selected.device;
}

std::optional<uint64_t> system_available_memory_bytes() {
    std::ifstream input("/proc/meminfo");
    std::string key;
    uint64_t value_kib = 0;
    std::string unit;
    while (input >> key >> value_kib >> unit) {
        if (key == "MemAvailable:") return value_kib * 1024;
    }
    return std::nullopt;
}

void preflight_production_v4_memory(const discovery::Device& device) {
    size_t free_bytes = 0;
    size_t total_bytes = 0;
    hip_check(hipMemGetInfo(&free_bytes, &total_bytes), "query HIP preflight memory");
    if (free_bytes < discovery::kMinimumProductionV4MemoryBytes) {
        fail("insufficient_available_memory: ProductionV4 batch 32 requires at least "
             + std::to_string(discovery::kMinimumProductionV4MemoryBytes)
             + " free HIP bytes; available=" + std::to_string(free_bytes));
    }

    std::optional<uint64_t> system_available;
    if (device.integrated == true) {
        system_available = system_available_memory_bytes();
        constexpr uint64_t kIntegratedSystemReserve = 2ULL * 1024 * 1024 * 1024;
        const uint64_t required =
            discovery::kMinimumProductionV4MemoryBytes + kIntegratedSystemReserve;
        if (!system_available || *system_available < required) {
            fail("insufficient_system_memory: integrated ProductionV4 requires "
                 + std::to_string(discovery::kMinimumProductionV4MemoryBytes)
                 + " bytes plus a 2 GiB operating-system reserve");
        }
    }
    std::cerr << "CMFD_HIP_MEMORY_PREFLIGHT required_free_bytes="
              << discovery::kMinimumProductionV4MemoryBytes
              << " hip_free_bytes=" << free_bytes
              << " hip_total_bytes=" << total_bytes
              << " system_available_bytes="
              << (system_available ? std::to_string(*system_available) : "not_required")
              << '\n';
}

void run_self_test() {
    constexpr int m = 8;
    constexpr int n = 32;
    constexpr int k = 64;
    std::vector<int8_t> a(m * k);
    std::vector<int8_t> b_row(k * n);
    std::vector<int8_t> b_column(k * n);
    for (int row = 0; row < m; ++row)
        for (int inner = 0; inner < k; ++inner)
            a[row * k + inner] = static_cast<int8_t>(((row * 17 + inner * 13) % 251) - 125);
    for (int inner = 0; inner < k; ++inner)
        for (int column = 0; column < n; ++column) {
            const int8_t value = static_cast<int8_t>(((inner * 29 + column * 7) % 251) - 125);
            b_row[inner * n + column] = value;
            b_column[column * k + inner] = value;
        }
    std::vector<int32_t> expected(m * n, 0);
    for (int row = 0; row < m; ++row)
        for (int column = 0; column < n; ++column)
            for (int inner = 0; inner < k; ++inner)
                expected[row * n + column] += int32_t{a[row * k + inner]} * int32_t{b_row[inner * n + column]};

    DeviceBuffer<int8_t> device_a(a.size());
    DeviceBuffer<int8_t> device_b(b_column.size());
    DeviceBuffer<int32_t> device_c(expected.size());
    hip_check(hipMemcpy(device_a.get(), a.data(), a.size(), hipMemcpyHostToDevice), "self-test copy A");
    hip_check(hipMemcpy(device_b.get(), b_column.data(), b_column.size(), hipMemcpyHostToDevice), "self-test copy B");
    rocblas_handle handle = nullptr;
    rocblas_check(rocblas_create_handle(&handle), "self-test rocblas_create_handle");
    const int32_t alpha = 1;
    const int32_t beta = 0;
    rocblas_check(rocblas_gemm_ex(handle,
                                  rocblas_operation_transpose,
                                  rocblas_operation_none,
                                  n,
                                  m,
                                  k,
                                  &alpha,
                                  device_b.get(),
                                  rocblas_datatype_i8_r,
                                  k,
                                  device_a.get(),
                                  rocblas_datatype_i8_r,
                                  k,
                                  &beta,
                                  device_c.get(),
                                  rocblas_datatype_i32_r,
                                  n,
                                  device_c.get(),
                                  rocblas_datatype_i32_r,
                                  n,
                                  rocblas_datatype_i32_r,
                                  rocblas_gemm_algo_standard,
                                  0,
                                  rocblas_gemm_flags_none),
                  "self-test int8 GEMM");
    hip_check(hipDeviceSynchronize(), "self-test synchronize GEMM");
    std::vector<int32_t> actual(expected.size());
    hip_check(hipMemcpy(actual.data(), device_c.get(), actual.size() * sizeof(int32_t), hipMemcpyDeviceToHost),
              "self-test copy C");
    rocblas_destroy_handle(handle);
    if (actual != expected) {
        for (size_t index = 0; index < actual.size(); ++index)
            if (actual[index] != expected[index])
                fail("int8 GEMM self-test mismatch at " + std::to_string(index) + ": expected " +
                     std::to_string(expected[index]) + ", got " + std::to_string(actual[index]));
    }

    const std::array<int64_t, 9> signed_values{
        -1100000000000000LL, -2130706434LL, -2130706433LL, -1LL, 0LL,
        1LL, 2130706432LL, 2130706433LL, 1100000000000000LL};
    for (int64_t value : signed_values) {
        const uint32_t reduced = cpu_field_reduce_signed(value);
        if (reduced >= kFieldPrime || cpu_field_cube(reduced) >= kFieldPrime)
            fail("field arithmetic self-test failed");
    }

    std::vector<int64_t> reduction_inputs(4096);
    uint64_t random_state = 0x9e3779b97f4a7c15ULL;
    for (size_t index = 0; index < reduction_inputs.size(); ++index) {
        random_state ^= random_state << 13;
        random_state ^= random_state >> 7;
        random_state ^= random_state << 17;
        const int64_t magnitude = static_cast<int64_t>(
            random_state % (static_cast<uint64_t>(kMaximumReconstructedMagnitude) + 1));
        reduction_inputs[index] = (index & 1U) ? -magnitude : magnitude;
    }
    std::vector<uint32_t> cube_inputs(reduction_inputs.size());
    for (size_t index = 0; index < cube_inputs.size(); ++index)
        cube_inputs[index] = static_cast<uint32_t>(
            (static_cast<uint64_t>(reduction_inputs[index] < 0
                 ? -reduction_inputs[index]
                 : reduction_inputs[index])) % kFieldPrime);
    cube_inputs[0] = 0;
    cube_inputs[1] = 1;
    cube_inputs[2] = kFieldPrime - 1;
    DeviceBuffer<uint32_t> device_cube_inputs(cube_inputs.size());
    DeviceBuffer<uint32_t> device_cube_outputs(cube_inputs.size());
    hip_check(hipMemcpy(device_cube_inputs.get(), cube_inputs.data(),
                        cube_inputs.size() * sizeof(uint32_t), hipMemcpyHostToDevice),
              "self-test copy cube inputs");
    hipLaunchKernelGGL(field_cube_self_test_kernel,
                       dim3((cube_inputs.size() + 255) / 256), dim3(256), 0, 0,
                       device_cube_inputs.get(), device_cube_outputs.get(),
                       static_cast<uint32_t>(cube_inputs.size()));
    hip_check(hipGetLastError(), "self-test launch field cube kernel");
    std::vector<uint32_t> cube_outputs(cube_inputs.size());
    hip_check(hipMemcpy(cube_outputs.data(), device_cube_outputs.get(),
                        cube_outputs.size() * sizeof(uint32_t), hipMemcpyDeviceToHost),
              "self-test copy cube outputs");
    for (size_t index = 0; index < cube_inputs.size(); ++index)
        if (cube_outputs[index] != cpu_field_cube(cube_inputs[index]))
            fail("field cube kernel self-test mismatch at " + std::to_string(index));
    const std::array<int64_t, 11> reduction_boundaries{
        -kMaximumReconstructedMagnitude, -static_cast<int64_t>(kFieldPrime) - 1,
        -static_cast<int64_t>(kFieldPrime), -static_cast<int64_t>(kFieldPrime) + 1,
        -1, 0, 1, static_cast<int64_t>(kFieldPrime) - 1,
        static_cast<int64_t>(kFieldPrime), static_cast<int64_t>(kFieldPrime) + 1,
        kMaximumReconstructedMagnitude};
    std::copy(reduction_boundaries.begin(), reduction_boundaries.end(), reduction_inputs.begin());
    DeviceBuffer<int64_t> device_reduction_inputs(reduction_inputs.size());
    DeviceBuffer<uint32_t> device_reduction_outputs(reduction_inputs.size());
    hip_check(hipMemcpy(device_reduction_inputs.get(), reduction_inputs.data(),
                        reduction_inputs.size() * sizeof(int64_t), hipMemcpyHostToDevice),
              "self-test copy reduction inputs");
    hipLaunchKernelGGL(field_reduce_self_test_kernel,
                       dim3((reduction_inputs.size() + 255) / 256), dim3(256), 0, 0,
                       device_reduction_inputs.get(), device_reduction_outputs.get(),
                       static_cast<uint32_t>(reduction_inputs.size()));
    hip_check(hipGetLastError(), "self-test launch field reduction kernel");
    std::vector<uint32_t> reduction_outputs(reduction_inputs.size());
    hip_check(hipMemcpy(reduction_outputs.data(), device_reduction_outputs.get(),
                        reduction_outputs.size() * sizeof(uint32_t), hipMemcpyDeviceToHost),
              "self-test copy reduction outputs");
    for (size_t index = 0; index < reduction_inputs.size(); ++index) {
        const uint32_t expected_reduction = cpu_field_reduce_signed(reduction_inputs[index]);
        if (reduction_outputs[index] != expected_reduction)
            fail("field reduction kernel self-test mismatch at " + std::to_string(index));
    }

    // Differential-test the HIP field kernels against a deliberately simple CPU
    // implementation.  Small power-of-two dimensions preserve the ProductionV4
    // coordinate-mask layout while keeping this test independent of the model bank.
    constexpr uint32_t test_rows = 4;
    constexpr uint32_t test_width = 8;
    constexpr uint32_t test_nonces = 2;
    constexpr uint64_t test_plane = uint64_t{test_rows} * test_width;
    constexpr uint64_t test_values = test_plane * test_nonces;
    constexpr uint32_t test_row_bits = 2;
    constexpr uint32_t test_column_bits = 3;
    std::vector<int8_t> test_base(test_plane);
    for (uint64_t index = 0; index < test_plane; ++index)
        test_base[index] = static_cast<int8_t>(static_cast<int32_t>((index * 37 + 11) % 251) - 125);
    std::vector<uint8_t> test_coefficients(
        uint64_t{test_nonces} * kStages * kCoefficientsPerStage);
    for (uint64_t index = 0; index < test_coefficients.size(); ++index)
        test_coefficients[index] = static_cast<uint8_t>((index * 197ULL + 17ULL) & 0xffU);

    DeviceBuffer<int8_t> device_base(test_base.size());
    DeviceBuffer<uint8_t> device_coefficients(test_coefficients.size());
    DeviceBuffer<int8_t> device_limbs(4 * test_values);
    DeviceBuffer<uint32_t> device_activations(test_values);
    hip_check(hipMemcpy(device_base.get(), test_base.data(), test_base.size(), hipMemcpyHostToDevice),
              "self-test copy base");
    hip_check(hipMemcpy(device_coefficients.get(), test_coefficients.data(),
                        test_coefficients.size(), hipMemcpyHostToDevice),
              "self-test copy coefficients");
    hipLaunchKernelGGL(initialize_activation_kernel, dim3(1), dim3(128), 0, 0,
                       device_base.get(), device_limbs.get(), device_activations.get(),
                       device_coefficients.get(), nullptr, nullptr,
                       test_rows, test_width, test_nonces);
    hip_check(hipGetLastError(), "self-test launch initialization kernel");
    std::vector<uint32_t> actual_activations(test_values);
    std::vector<int8_t> actual_limbs(4 * test_values);
    hip_check(hipMemcpy(actual_activations.data(), device_activations.get(),
                        actual_activations.size() * sizeof(uint32_t), hipMemcpyDeviceToHost),
              "self-test copy initialized activations");
    hip_check(hipMemcpy(actual_limbs.data(), device_limbs.get(), actual_limbs.size(), hipMemcpyDeviceToHost),
              "self-test copy initialized limbs");
    auto encoded_limb = [](uint32_t value, uint32_t limb) {
        const uint32_t byte = (value >> (8 * limb)) & 0xffU;
        return static_cast<int8_t>(limb == 3 ? (byte | 0x80U) : (byte ^ 0x80U));
    };
    for (uint32_t nonce = 0; nonce < test_nonces; ++nonce) {
        const uint8_t* coefficients = test_coefficients.data() +
            uint64_t{nonce} * kStages * kCoefficientsPerStage;
        for (uint32_t row = 0; row < test_rows; ++row) {
            for (uint32_t column = 0; column < test_width; ++column) {
                const uint64_t within = uint64_t{row} * test_width + column;
                const uint64_t index = uint64_t{nonce} * test_plane + within;
                uint32_t value = test_base[within] < 0
                    ? static_cast<uint32_t>(static_cast<int64_t>(test_base[within]) + kFieldPrime)
                    : static_cast<uint32_t>(test_base[within]);
                value += cpu_mask(coefficients, row, column, test_row_bits, test_column_bits);
                if (value >= kFieldPrime) value -= kFieldPrime;
                value = cpu_field_cube(value);
                if (actual_activations[index] != value)
                    fail("initialization kernel self-test mismatch at " + std::to_string(index));
                for (uint32_t limb = 0; limb < 4; ++limb)
                    if (actual_limbs[uint64_t{nonce} * 4 * test_plane +
                                     uint64_t{limb} * test_plane + within] != encoded_limb(value, limb))
                        fail("initialization limb self-test mismatch at " + std::to_string(index));
            }
        }
    }

    constexpr uint32_t test_layer = 7;
    std::vector<int32_t> test_accumulators(4 * test_values);
    for (uint64_t index = 0; index < test_accumulators.size(); ++index)
        test_accumulators[index] = static_cast<int32_t>((index * 7919ULL + 101ULL) % 2000001ULL) - 1000000;
    std::vector<int64_t> test_weight_biases(test_width);
    for (uint32_t column = 0; column < test_width; ++column)
        test_weight_biases[column] =
            (static_cast<int64_t>(column * 1301) - 4200) * kDigitBias;
    DeviceBuffer<int32_t> device_accumulators(test_accumulators.size());
    DeviceBuffer<int64_t> device_weight_biases(test_weight_biases.size());
    DeviceBuffer<uint32_t> device_preactivations(test_values);
    hip_check(hipMemcpy(device_accumulators.get(), test_accumulators.data(),
                        test_accumulators.size() * sizeof(int32_t), hipMemcpyHostToDevice),
              "self-test copy accumulators");
    hip_check(hipMemcpy(device_weight_biases.get(), test_weight_biases.data(),
                        test_weight_biases.size() * sizeof(int64_t), hipMemcpyHostToDevice),
              "self-test copy weight biases");
    hipLaunchKernelGGL(reduce_layer_kernel, dim3(1), dim3(128), 0, 0,
                       device_accumulators.get(), device_limbs.get(), device_preactivations.get(),
                       device_activations.get(), device_coefficients.get(), nullptr, nullptr,
                       device_weight_biases.get(),
                       test_layer, test_rows, test_width, test_nonces);
    hip_check(hipGetLastError(), "self-test launch reduction kernel");
    std::vector<uint32_t> actual_preactivations(test_values);
    hip_check(hipMemcpy(actual_preactivations.data(), device_preactivations.get(),
                        actual_preactivations.size() * sizeof(uint32_t), hipMemcpyDeviceToHost),
              "self-test copy preactivations");
    hip_check(hipMemcpy(actual_activations.data(), device_activations.get(),
                        actual_activations.size() * sizeof(uint32_t), hipMemcpyDeviceToHost),
              "self-test copy reduced activations");
    hip_check(hipMemcpy(actual_limbs.data(), device_limbs.get(), actual_limbs.size(), hipMemcpyDeviceToHost),
              "self-test copy reduced limbs");
    for (uint32_t nonce = 0; nonce < test_nonces; ++nonce) {
        const uint8_t* coefficients = test_coefficients.data() +
            (uint64_t{nonce} * kStages + test_layer + 1) * kCoefficientsPerStage;
        for (uint32_t row = 0; row < test_rows; ++row) {
            for (uint32_t column = 0; column < test_width; ++column) {
                const uint64_t within = uint64_t{row} * test_width + column;
                const uint64_t index = uint64_t{nonce} * test_plane + within;
                const uint64_t accumulator_base = uint64_t{nonce} * 4 * test_plane + within;
                const int64_t reconstructed =
                    static_cast<int64_t>(test_accumulators[accumulator_base]) +
                    static_cast<int64_t>(test_accumulators[accumulator_base + test_plane]) * 256LL +
                    static_cast<int64_t>(test_accumulators[accumulator_base + 2 * test_plane]) * 65536LL +
                    static_cast<int64_t>(test_accumulators[accumulator_base + 3 * test_plane]) * 16777216LL +
                    test_weight_biases[column];
                uint32_t preactivation = cpu_field_reduce_signed(reconstructed);
                preactivation += cpu_mask(coefficients, row, column, test_row_bits, test_column_bits);
                if (preactivation >= kFieldPrime) preactivation -= kFieldPrime;
                const uint32_t value = cpu_field_cube(preactivation);
                if (actual_preactivations[index] != preactivation || actual_activations[index] != value)
                    fail("reduction kernel self-test mismatch at " + std::to_string(index));
                for (uint32_t limb = 0; limb < 4; ++limb)
                    if (actual_limbs[uint64_t{nonce} * 4 * test_plane +
                                     uint64_t{limb} * test_plane + within] != encoded_limb(value, limb))
                        fail("reduction limb self-test mismatch at " + std::to_string(index));
            }
        }
    }
    std::cerr << "CMFD_HIP_SELF_TEST PASS int8_gemm=exact init_kernel=exact reduce_kernel=exact "
                 "field_arithmetic=canonical\n";
}

void benchmark_gemm_solutions(uint32_t nonce_count, uint32_t iterations) {
    if (nonce_count < 1 || nonce_count > 64 || iterations < 1) fail("invalid GEMM benchmark dimensions");
    const rocblas_int gemm_m = kDimension;
    const rocblas_int gemm_n = static_cast<rocblas_int>(4U * kRows * nonce_count);
    const rocblas_int gemm_k = kDimension;
    DeviceBuffer<int8_t> weights(kLayerElements);
    DeviceBuffer<int8_t> limbs(static_cast<uint64_t>(gemm_n) * gemm_k);
    DeviceBuffer<int32_t> accumulators(static_cast<uint64_t>(gemm_m) * gemm_n);
    hip_check(hipMemset(weights.get(), 1, weights.size()), "initialize GEMM benchmark weights");
    hip_check(hipMemset(limbs.get(), 1, limbs.size()), "initialize GEMM benchmark activations");
    hip_check(hipMemset(accumulators.get(), 0, accumulators.size() * sizeof(int32_t)),
              "initialize GEMM benchmark output");
    rocblas_handle handle = nullptr;
    rocblas_check(rocblas_create_handle(&handle), "benchmark rocblas_create_handle");
    const int32_t alpha = 1;
    const int32_t beta = 0;
    rocblas_int solution_count = 0;
    rocblas_check(rocblas_gemm_ex_get_solutions(handle,
                                                rocblas_operation_transpose,
                                                rocblas_operation_none,
                                                gemm_m,
                                                gemm_n,
                                                gemm_k,
                                                &alpha,
                                                weights.get(),
                                                rocblas_datatype_i8_r,
                                                gemm_k,
                                                limbs.get(),
                                                rocblas_datatype_i8_r,
                                                gemm_k,
                                                &beta,
                                                accumulators.get(),
                                                rocblas_datatype_i32_r,
                                                gemm_m,
                                                accumulators.get(),
                                                rocblas_datatype_i32_r,
                                                gemm_m,
                                                rocblas_datatype_i32_r,
                                                rocblas_gemm_algo_standard,
                                                rocblas_gemm_flags_none,
                                                nullptr,
                                                &solution_count),
                  "query GEMM solution count");
    std::vector<rocblas_int> solutions(solution_count);
    rocblas_check(rocblas_gemm_ex_get_solutions(handle,
                                                rocblas_operation_transpose,
                                                rocblas_operation_none,
                                                gemm_m,
                                                gemm_n,
                                                gemm_k,
                                                &alpha,
                                                weights.get(),
                                                rocblas_datatype_i8_r,
                                                gemm_k,
                                                limbs.get(),
                                                rocblas_datatype_i8_r,
                                                gemm_k,
                                                &beta,
                                                accumulators.get(),
                                                rocblas_datatype_i32_r,
                                                gemm_m,
                                                accumulators.get(),
                                                rocblas_datatype_i32_r,
                                                gemm_m,
                                                rocblas_datatype_i32_r,
                                                rocblas_gemm_algo_standard,
                                                rocblas_gemm_flags_none,
                                                solutions.data(),
                                                &solution_count),
                  "query GEMM solutions");
    solutions.resize(solution_count);
    std::cout << "solution,nonce_count,m,n,k,milliseconds,tops\n";
    rocblas_int best_solution = 0;
    double best_ms = std::numeric_limits<double>::infinity();
    for (rocblas_int solution : solutions) {
        auto launch = [&]() {
            return rocblas_gemm_ex(handle,
                                   rocblas_operation_transpose,
                                   rocblas_operation_none,
                                   gemm_m,
                                   gemm_n,
                                   gemm_k,
                                   &alpha,
                                   weights.get(),
                                   rocblas_datatype_i8_r,
                                   gemm_k,
                                   limbs.get(),
                                   rocblas_datatype_i8_r,
                                   gemm_k,
                                   &beta,
                                   accumulators.get(),
                                   rocblas_datatype_i32_r,
                                   gemm_m,
                                   accumulators.get(),
                                   rocblas_datatype_i32_r,
                                   gemm_m,
                                   rocblas_datatype_i32_r,
                                   rocblas_gemm_algo_solution_index,
                                   solution,
                                   rocblas_gemm_flags_none);
        };
        if (launch() != rocblas_status_success) continue;
        hip_check(hipDeviceSynchronize(), "warm up GEMM solution");
        hipEvent_t start = nullptr;
        hipEvent_t stop = nullptr;
        hip_check(hipEventCreate(&start), "create GEMM benchmark start event");
        hip_check(hipEventCreate(&stop), "create GEMM benchmark stop event");
        hip_check(hipEventRecord(start), "record GEMM benchmark start");
        bool valid = true;
        for (uint32_t iteration = 0; iteration < iterations; ++iteration) {
            if (launch() != rocblas_status_success) {
                valid = false;
                break;
            }
        }
        hip_check(hipEventRecord(stop), "record GEMM benchmark stop");
        hip_check(hipEventSynchronize(stop), "finish GEMM benchmark solution");
        float elapsed_ms = 0.0F;
        hip_check(hipEventElapsedTime(&elapsed_ms, start, stop), "measure GEMM benchmark solution");
        hip_check(hipEventDestroy(stop), "destroy GEMM benchmark stop event");
        hip_check(hipEventDestroy(start), "destroy GEMM benchmark start event");
        if (!valid) continue;
        const double average_ms = elapsed_ms / iterations;
        const double operations = 2.0 * gemm_m * static_cast<double>(gemm_n) * gemm_k;
        const double tops = operations / (average_ms / 1000.0) / 1.0e12;
        std::cout << solution << ',' << nonce_count << ',' << gemm_m << ',' << gemm_n << ',' << gemm_k << ','
                  << std::fixed << std::setprecision(6) << average_ms << ',' << tops << '\n';
        if (average_ms < best_ms) {
            best_ms = average_ms;
            best_solution = solution;
        }
    }
    std::cerr << std::fixed << std::setprecision(6) << "CMFD_HIP_GEMM_BEST nonce_count=" << nonce_count
              << " solution=" << best_solution << " milliseconds=" << best_ms << '\n';
    rocblas_destroy_handle(handle);
}

void server_loop(
    const std::string& model_path, int32_t solution_index, bool use_graph,
    uint32_t workgroup_size, bool precompute_masks, const std::string& architecture) {
    ProductionModel model(model_path);
    model.load();
    ReplayEngine engine(
        model, architecture, solution_index, use_graph, workgroup_size, precompute_masks);
    class Handler final : public protocol::ServerCommandHandler {
      public:
        Handler(ProductionModel& model, ReplayEngine& engine) : model_(model), engine_(engine) {}

        void run_batch(uint32_t count, const std::string& coefficients,
                       const std::string& output) override {
            engine_.run_batch(count, coefficients, output);
        }

        void evict() override {
            engine_.reset_workspace();
            model_.evict();
            hip_check(hipDeviceSynchronize(), "evict ProductionV4 model");
        }

      private:
        ProductionModel& model_;
        ReplayEngine& engine_;
    } handler(model, engine);
    (void)protocol::run_server_protocol(std::cin, std::cout, &std::cerr, handler);
}

}  // namespace cmfd_hip

int main(int argc, char** argv) {
    try {
        int device = -1;
        std::optional<std::string> device_selector;
        int32_t solution_index = cmfd_hip::ReplayEngine::kAutoSolution;
        bool use_graph = true;
        uint32_t workgroup_size = 512;
        bool precompute_masks = true;
        std::vector<std::string> arguments;
        for (int index = 1; index < argc; ++index) {
            if (std::string(argv[index]) == "--device") {
                if (++index >= argc) cmfd_hip::fail("--device requires an integer");
                device = std::stoi(argv[index]);
                if (device < -1) cmfd_hip::fail("--device must be a non-negative HIP index");
            } else if (std::string(argv[index]) == "--device-selector") {
                if (++index >= argc) cmfd_hip::fail("--device-selector requires a selector");
                device_selector = argv[index];
            } else if (std::string(argv[index]) == "--solution") {
                if (++index >= argc) cmfd_hip::fail("--solution requires an integer");
                solution_index = static_cast<int32_t>(std::stol(argv[index]));
            } else if (std::string(argv[index]) == "--no-graph") {
                use_graph = false;
            } else if (std::string(argv[index]) == "--workgroup-size") {
                if (++index >= argc) cmfd_hip::fail("--workgroup-size requires an integer");
                workgroup_size = static_cast<uint32_t>(std::stoul(argv[index]));
            } else if (std::string(argv[index]) == "--precompute-masks") {
                precompute_masks = true;
            } else if (std::string(argv[index]) == "--no-precompute-masks") {
                precompute_masks = false;
            } else {
                arguments.emplace_back(argv[index]);
            }
        }
        const bool supervised_server =
            arguments.size() == 2 && arguments[0] == "--server";
        cmfd_hip::protocol::install_termination_signal_handlers(
            supervised_server
                ? cmfd_hip::protocol::SigintBehavior::defer_to_supervisor
                : cmfd_hip::protocol::SigintBehavior::terminate);
        const cmfd_hip::discovery::Device selected_device =
            cmfd_hip::select_device(device, device_selector);
        const std::string selected_architecture =
            cmfd_hip::discovery::base_architecture(selected_device.architecture);
        if (arguments.size() == 1 && arguments[0] == "--self-test") {
            cmfd_hip::run_self_test();
            return 0;
        }
        if (arguments.size() == 2 && arguments[0] == "--server") {
            cmfd_hip::preflight_production_v4_memory(selected_device);
            cmfd_hip::run_self_test();
            std::cerr << "CMFD_HIP_COMPATIBILITY_VALIDATED arch="
                      << selected_architecture << " batch=32\n";
            cmfd_hip::server_loop(
                arguments[1], solution_index, use_graph, workgroup_size, precompute_masks,
                selected_architecture);
            return 0;
        }
        if ((arguments.size() == 2 || arguments.size() == 3) && arguments[0] == "--benchmark-gemm") {
            const uint32_t count = static_cast<uint32_t>(std::stoul(arguments[1]));
            const uint32_t iterations = arguments.size() == 3 ? static_cast<uint32_t>(std::stoul(arguments[2])) : 10;
            cmfd_hip::benchmark_gemm_solutions(count, iterations);
            return 0;
        }
        if (arguments.size() == 5 && arguments[0] == "--run-batch") {
            const uint32_t count = static_cast<uint32_t>(std::stoul(arguments[1]));
            cmfd_hip::preflight_production_v4_memory(selected_device);
            cmfd_hip::run_self_test();
            std::cerr << "CMFD_HIP_COMPATIBILITY_VALIDATED arch="
                      << selected_architecture << " batch=" << count << "\n";
            cmfd_hip::ProductionModel model(arguments[2]);
            cmfd_hip::ReplayEngine engine(
                model, selected_architecture, solution_index, use_graph,
                workgroup_size, precompute_masks);
            engine.run_batch(count, arguments[3], arguments[4]);
            return 0;
        }
        std::cerr << "usage:\n"
                  << "  DEVICE is --device N or --device-selector {uuid:UUID|pci:BDF|hip:N}\n"
                  << "  cmfd-v4-hip-replay [DEVICE] --self-test\n"
                  << "  cmfd-v4-hip-replay [DEVICE] --benchmark-gemm COUNT [ITERATIONS]\n"
                  << "  cmfd-v4-hip-replay [DEVICE] [--solution INDEX] [--workgroup-size N] [--no-precompute-masks] [--no-graph] --server MODEL\n"
                  << "  cmfd-v4-hip-replay [DEVICE] [--solution INDEX] [--workgroup-size N] [--no-precompute-masks] [--no-graph] --run-batch COUNT MODEL COEFFICIENTS OUTPUT\n";
        return 2;
    } catch (const std::exception& error) {
        std::cerr << "CMFD_HIP_ERROR " << error.what() << '\n';
        return 1;
    }
}
