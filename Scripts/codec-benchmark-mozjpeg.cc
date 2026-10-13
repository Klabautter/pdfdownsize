#include <cstdio>
#include <cstdlib>
#include <vector>
#include <jpeglib.h>

// Match pdfcore_jpeg_encode, but accept a raw RGB fixture for isolated benchmarks.
int main(int argc, char** argv) {
    if (argc != 6) return 2;
    int width = std::atoi(argv[2]), height = std::atoi(argv[3]);
    int quality = std::atoi(argv[4]);
    if (width <= 0 || height <= 0 || quality < 1 || quality > 100) return 2;
    std::vector<unsigned char> pixels(static_cast<size_t>(width) * height * 3);
    FILE* input = std::fopen(argv[1], "rb");
    if (!input) return 3;
    size_t read = std::fread(pixels.data(), 1, pixels.size(), input);
    std::fclose(input);
    if (read != pixels.size()) return 3;
    FILE* output = std::fopen(argv[5], "wb");
    if (!output) return 3;
    jpeg_compress_struct cinfo{};
    jpeg_error_mgr errors{};
    cinfo.err = jpeg_std_error(&errors);
    jpeg_create_compress(&cinfo);
    jpeg_c_set_int_param(&cinfo, JINT_COMPRESS_PROFILE, JCP_MAX_COMPRESSION);
    cinfo.image_width = width;
    cinfo.image_height = height;
    cinfo.input_components = 3;
    cinfo.in_color_space = JCS_RGB;
    jpeg_set_defaults(&cinfo);
    jpeg_set_quality(&cinfo, quality, TRUE);
    jpeg_stdio_dest(&cinfo, output);
    jpeg_start_compress(&cinfo, TRUE);
    while (cinfo.next_scanline < cinfo.image_height) {
        JSAMPROW row = pixels.data() + static_cast<size_t>(cinfo.next_scanline) * width * 3;
        jpeg_write_scanlines(&cinfo, &row, 1);
    }
    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);
    return std::fclose(output) == 0 ? 0 : 3;
}
