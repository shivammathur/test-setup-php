#include <ultrahdr_api.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void check(uhdr_error_info_t error, const char *operation) {
    if (error.error_code != UHDR_CODEC_OK) {
        fprintf(stderr, "%s: %d %s\n", operation, error.error_code, error.has_detail ? error.detail : "");
        exit(1);
    }
}

int main(void) {
    enum { W = 64, H = 64 };
    uint16_t y[W * H], uv[W * H / 2];
    uhdr_raw_image_t input = {0};
    uhdr_raw_image_t *output, *gainmap;
    uhdr_compressed_image_t *encoded;
    uhdr_codec_private_t *encoder = uhdr_create_encoder(), *decoder = uhdr_create_decoder();
    int i;
    if (!encoder || !decoder) return 2;
    for (i = 0; i < W * H; i++) y[i] = (uint16_t)((256 + (i % W) * 8) << 6);
    for (i = 0; i < W * H / 2; i++) uv[i] = 512 << 6;
    input.fmt = UHDR_IMG_FMT_24bppYCbCrP010;
    input.cg = UHDR_CG_BT_2100;
    input.ct = UHDR_CT_HLG;
    input.range = UHDR_CR_LIMITED_RANGE;
    input.w = W; input.h = H;
    input.planes[UHDR_PLANE_Y] = y; input.planes[UHDR_PLANE_UV] = uv;
    input.stride[UHDR_PLANE_Y] = W; input.stride[UHDR_PLANE_UV] = W;
    check(uhdr_enc_set_raw_image(encoder, &input, UHDR_HDR_IMG), "set HDR image");
    check(uhdr_encode(encoder), "encode HDR JPEG");
    encoded = uhdr_get_encoded_stream(encoder);
    if (!encoded || encoded->data_sz < 100 || !is_uhdr_image(encoded->data, (int)encoded->data_sz)) return 3;
    check(uhdr_dec_set_image(decoder, encoded), "set encoded image");
    check(uhdr_dec_set_out_img_format(decoder, UHDR_IMG_FMT_32bppRGBA8888), "set SDR pixels");
    check(uhdr_dec_set_out_color_transfer(decoder, UHDR_CT_SRGB), "set SDR transfer");
    check(uhdr_decode(decoder), "decode HDR JPEG");
    output = uhdr_get_decoded_image(decoder);
    gainmap = uhdr_get_decoded_gainmap_image(decoder);
    if (!output || output->w != W || output->h != H || !output->planes[0] ||
        !gainmap || !gainmap->w || !gainmap->h || !gainmap->planes[0]) return 4;
    if (((unsigned char *)output->planes[0])[0] >= ((unsigned char *)output->planes[0])[4 * (W - 1)]) return 5;
    printf("UltraHDR JPEG encode/decode, gainmap and gradient passed (%zu bytes)\n", encoded->data_sz);
    uhdr_release_decoder(decoder);
    uhdr_release_encoder(encoder);
    return 0;
}
