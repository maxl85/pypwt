#include "filters.h"
#include "common.h"

#define MAX_FILTER_WIDTH 40

#  define CUDACHECK \
  { cudaThreadSynchronize(); \
    cudaError_t last = cudaGetLastError();\
    if(last!=cudaSuccess) {\
      printf("ERRORX: %s  %s  %i \n", cudaGetErrorString( last),    __FILE__, __LINE__    );    \
      exit(1);\
    }\
  }




__constant__ float c_kern_L[MAX_FILTER_WIDTH];
__constant__ float c_kern_H[MAX_FILTER_WIDTH];
__constant__ float c_kern_IL[MAX_FILTER_WIDTH];
__constant__ float c_kern_IH[MAX_FILTER_WIDTH];




/// Compute the low-pass and high-pass filters for separable convolutions.
/// wname: name of the filter ("haar", "db3", "sym4", ...)
/// Returns : the filter width "hlen" if success ; a negative value otherwise.
int w_compute_filters_separable(const char* wname, int do_swt) {
    int hlen = 0;
    float* f1_l, *f1_h, *f1_il, *f1_ih;

    // Haar filters has specific kernels
    if (!do_swt) {
        if ((!strcasecmp(wname, "haar")) || (!strcasecmp(wname, "db1")) || (!strcasecmp(wname, "bior1.1")) || (!strcasecmp(wname, "rbior1.1"))) {
            return 2;
        }
    }

    // Browse available filters (see filters.h)
    int i;
    for (i = 0; i < 72; i++) {
        if (!strcasecmp(wname, all_filters[i].wname)) {
            hlen = all_filters[i].hlen;
            f1_l = all_filters[i].f_l;
            f1_h = all_filters[i].f_h;
            f1_il = all_filters[i].i_l;
            f1_ih = all_filters[i].i_h;
            break;
        }
    }
    if (hlen == 0) {
        printf("ERROR: w_compute_filters(): unknown filter %s\n", wname);
        return -2;
    }

    // Copy the filters to device constant memory
    cudaMemcpyToSymbol(c_kern_L, f1_l, hlen*sizeof(float), 0, cudaMemcpyHostToDevice);
    cudaMemcpyToSymbol(c_kern_H, f1_h, hlen*sizeof(float), 0, cudaMemcpyHostToDevice);
    cudaMemcpyToSymbol(c_kern_IL, f1_il, hlen*sizeof(float), 0, cudaMemcpyHostToDevice);
    cudaMemcpyToSymbol(c_kern_IH, f1_ih, hlen*sizeof(float), 0, cudaMemcpyHostToDevice);

    return hlen;
}





/// ----------------------------------------------------------------------------
/// ---------------------------- Forward DWT  ----------------------------------
/// ----------------------------------------------------------------------------




// must be run with grid size = (Nc/2, Nr)  where Nr = numrows of input image
// Pass 1 : Input image ==> horizontal convolution with L, H  + horizontal subsampling  ==> (tmp_a1, tmp_a2)
__global__ void w_kern_forward_pass1(float* img, float* tmp_a1, float* tmp_a2, int Nr, int Nc, int hlen) {
    int gidx = threadIdx.x + blockIdx.x*blockDim.x;
    int gidy = threadIdx.y + blockIdx.y*blockDim.y;
    int Nc2 = Nc/2;
    if (gidy < Nr && gidx < Nc2) { // horiz subsampling : Input (Nr, Nc) => Output (Nr, Nc/2)
        int c, hL, hR;
        if (hlen & 1) { // odd kernel size
            c = hlen/2;
            hL = c;
            hR = c;
        }
        else { // even kernel size : center is shifted to the left
            c = hlen/2 - 1;
            hL = c;
            hR = c+1;
        }
        int jx1 = c - 2*gidx;
        int jx2 = Nc - 1 - 2*gidx + c;
        float res_tmp_a1 = 0, res_tmp_a2 = 0;
        float img_val;

        // Convolution with periodic boundaries extension.
        for (int jx = 0; jx <= hR+hL; jx++) {
            int idx_x = gidx*2 - c + jx;
            if (jx < jx1) idx_x += Nc;
            if (jx > jx2) idx_x -= Nc ;

            img_val = img[(gidy*1)*Nc + idx_x]; // <=
            res_tmp_a1 += img_val * c_kern_L[hlen-1 - jx];
            res_tmp_a2 += img_val * c_kern_H[hlen-1 - jx];
        }
        tmp_a1[gidy* Nc2 + gidx] = res_tmp_a1;
        tmp_a2[gidy* Nc2 + gidx] = res_tmp_a2;
    }
}

// must be run with grid size = (Nc/2, Nr/2)  where Nr = numrows of input image. Here Nc is actually halved wrt to Nc_image since there was a horiz subs.
// Pass 2 : (tmp_a1, tmp_a2) ==>  Vertic convolution on tmp_a1 and tmp_a2 with  L, H  + vertical subsampling ==> (a, h, v, d)
__global__ void w_kern_forward_pass2(float* tmp_a1, float* tmp_a2, float* c_a, float* c_h, float* c_v, float* c_d, int Nr, int Nc, int hlen) {
    int gidx = threadIdx.x + blockIdx.x*blockDim.x;
    int gidy = threadIdx.y + blockIdx.y*blockDim.y;
    int Nr2 = Nr/2;
    if (gidy < Nr2 && gidx < Nc) { // vertic subsampling : Input (Nr, Nc/2) => Output (Nr/2, Nc/2)
        int c, hL, hR;
        if (hlen & 1) { // odd kernel size
            c = hlen/2;
            hL = c;
            hR = c;
        }
        else { // even kernel size : center is shifted to the left
            c = hlen/2 - 1;
            hL = c;
            hR = c+1;
        }
        int jy1 = c - gidy*2;
        int jy2 = Nr - 1 - gidy*2 + c;
        float res_a = 0, res_h = 0, res_v = 0, res_d = 0;

        // Convolution with periodic boundaries extension.
        for (int jy = 0; jy <= hR+hL; jy++) {
            int idx_y = gidy*2 - c + jy;
            if (jy < jy1) idx_y += Nr;
            if (jy > jy2) idx_y -= Nr ;

            res_a += tmp_a1[idx_y*Nc + gidx] * c_kern_L[hlen-1 - jy];
            res_h += tmp_a1[idx_y*Nc + gidx] * c_kern_H[hlen-1 - jy];
            res_v += tmp_a2[idx_y*Nc + gidx] * c_kern_L[hlen-1 - jy];
            res_d += tmp_a2[idx_y*Nc + gidx] * c_kern_H[hlen-1 - jy];
        }

        c_a[gidy* Nc + gidx] = res_a;
        c_h[gidy* Nc + gidx] = res_h;
        c_v[gidy* Nc + gidx] = res_v;
        c_d[gidy* Nc + gidx] = res_d;
    }
}


int w_forward_separable(float* d_image, float** d_coeffs, float* d_tmp, int Nr, int Nc, int levels, int hlen) {
    float* d_tmp1 = d_tmp;
    float* d_tmp2 = d_tmp + Nr*Nc/2;

    // First level
    int tpb = 16; // TODO : tune for max perfs.
    int Nc2 = Nc/2, Nr2 = Nr/2;

    dim3 n_blocks_1 = dim3(w_iDivUp(Nc2, tpb), w_iDivUp(Nr, tpb), 1);
    dim3 n_blocks_2 = dim3(w_iDivUp(Nc2, tpb), w_iDivUp(Nr2, tpb), 1);
    dim3 n_threads_per_block = dim3(tpb, tpb, 1);

    w_kern_forward_pass1<<<n_blocks_1, n_threads_per_block>>>(d_image, d_tmp1, d_tmp2, Nr2*2, Nc2*2, hlen);
    w_kern_forward_pass2<<<n_blocks_2, n_threads_per_block>>>(d_tmp1, d_tmp2, d_coeffs[0], d_coeffs[1], d_coeffs[2], d_coeffs[3], Nr2*2, Nc2, hlen);

    for (int i=1; i < levels; i++) {
        Nc2 /= 2;
        Nr2 /= 2;
        n_blocks_1 = dim3(w_iDivUp(Nc2, tpb), w_iDivUp(Nr2*2, tpb), 1);
        n_blocks_2 = dim3(w_iDivUp(Nc2, tpb), w_iDivUp(Nr2, tpb), 1);
        w_kern_forward_pass1<<<n_blocks_1, n_threads_per_block>>>(d_coeffs[0], d_tmp1, d_tmp2, Nr2*2, Nc2*2, hlen);
        w_kern_forward_pass2<<<n_blocks_2, n_threads_per_block>>>(d_tmp1, d_tmp2, d_coeffs[0], d_coeffs[3*i+1], d_coeffs[3*i+2], d_coeffs[3*i+3], Nr2*2, Nc2, hlen);
    }
    return 0;
}



/// ----------------------------------------------------------------------------
/// ---------------------------- Inverse DWT -----------------------------------
/// ----------------------------------------------------------------------------

// must be run with grid size = (Nc, 2*Nr) ; Nr = numrows of input coefficients
// pass 1 : (a, h, v, d)  ==> Vertical convol with IL, IH  +  vertical oversampling==> (tmp1, tmp2)
__global__ void w_kern_inverse_pass1(float* c_a, float* c_h, float* c_v, float* c_d, float* tmp1, float* tmp2, int Nr, int Nc, int hlen) {
    int gidx = threadIdx.x + blockIdx.x*blockDim.x;
    int gidy = threadIdx.y + blockIdx.y*blockDim.y;
    int Nr2 = Nr*2;
    if (gidy < Nr2 && gidx < Nc) { // vertic oversampling : Input (Nr, Nc) => Output (Nr*2, Nc)
        int c, hL, hR;
        int hlen2 = hlen/2; // Convolutions with even/odd indices of the kernels
        if (hlen2 & 1) { // odd half-kernel size
            c = hlen2/2;
            hL = c;
            hR = c;
        }
        else { // even half-kernel size : center is shifted to the RIGHT for reconstruction.
            c = hlen2/2 - 0;
            hL = c;
            hR = c-1;
            // virtual id for shift
            // TODO : for the very first convolution (on the edges), this is not exactly accurate (?)
            gidy += 1;
        }
        int jy1 = c - gidy/2;
        int jy2 = Nr - 1 - gidy/2 + c;
        int offset_y = 1-(gidy & 1);

        float res_a = 0, res_h = 0, res_v = 0, res_d = 0;
        for (int jy = 0; jy <= hR+hL; jy++) {
            int idx_y = gidy/2 - c + jy;
            if (jy < jy1) idx_y += Nr;
            if (jy > jy2) idx_y -= Nr;

            res_a += c_a[idx_y*Nc + gidx] * c_kern_IL[hlen-1 - (2*jy + offset_y)];
            res_h += c_h[idx_y*Nc + gidx] * c_kern_IH[hlen-1 - (2*jy + offset_y)];
            res_v += c_v[idx_y*Nc + gidx] * c_kern_IL[hlen-1 - (2*jy + offset_y)];
            res_d += c_d[idx_y*Nc + gidx] * c_kern_IH[hlen-1 - (2*jy + offset_y)];
        }
        if ((hlen2 & 1) == 1) {
            tmp1[gidy * Nc + gidx] = res_a + res_h;
            tmp2[gidy * Nc + gidx] = res_v + res_d;
        }
        else {
            tmp1[(gidy-1) * Nc + gidx] = res_a + res_h;
            tmp2[(gidy-1) * Nc + gidx] = res_v + res_d;
         }
    }
}

// must be run with grid size = (2*Nr, 2*Nc) ; Nc = numcols of input coeffs. Here the param Nr is actually doubled wrt Nr_coeffs because of the vertical oversampling.
// pass 2 : (tmp1, tmp2)  ==> Horiz convol with IL, IH  + horiz oversampling ==> I
__global__ void w_kern_inverse_pass2(float* tmp1, float* tmp2, float* img, int Nr, int Nc, int hlen) {
    int gidx = threadIdx.x + blockIdx.x*blockDim.x;
    int gidy = threadIdx.y + blockIdx.y*blockDim.y;
    int Nc2 = Nc*2;
    if (gidy < Nr && gidx < Nc2) { // horiz oversampling : Input (Nr*2, Nc) => Output (Nr*2, Nc*2)
        int c, hL, hR;
        int hlen2 = hlen/2; // Convolutions with even/odd indices of the kernels
        if (hlen2 & 1) { // odd half-kernel size
            c = hlen2/2;
            hL = c;
            hR = c;
        }
        else { // even half-kernel size : center is shifted to the RIGHT for reconstruction.
            c = hlen2/2 - 0;
            hL = c;
            hR = c-1;
            // virtual id for shift
            // TODO : for the very first convolution (on the edges), this is not exactly accurate (?)
            gidx += 1;
        }
        int jx1 = c - gidx/2;
        int jx2 = Nc - 1 - gidx/2 + c;
        int offset_x = 1-(gidx & 1);

        float res_1 = 0, res_2 = 0;
        for (int jx = 0; jx <= hR+hL; jx++) {
            int idx_x = gidx/2 - c + jx;
            if (jx < jx1) idx_x += Nc;
            if (jx > jx2) idx_x -= Nc;

            res_1 += tmp1[gidy*Nc + idx_x] * c_kern_IL[hlen-1 - (2*jx + offset_x)];
            res_2 += tmp2[gidy*Nc + idx_x] * c_kern_IH[hlen-1 - (2*jx + offset_x)];
        }
        if ((hlen2 & 1) == 1) img[gidy * Nc2 + gidx] = res_1 + res_2;
        else img[gidy * Nc2 + (gidx-1)] = res_1 + res_2;
    }
}


int w_inverse_separable(float* d_image, float** d_coeffs, float* d_tmp, int Nr, int Nc, int levels, int hlen) {
    float* d_tmp1 = d_tmp;
    float* d_tmp2 = d_tmp + Nr*Nc/2;

    Nr /= w_ipow2(levels);
    Nc /= w_ipow2(levels);

    int tpb = 16; // TODO : tune for max perfs.
    int Nc2 = Nc*2, Nr2 = Nr*2;
    dim3 n_blocks_1, n_blocks_2;
    dim3 n_threads_per_block = dim3(tpb, tpb, 1);

    for (int i = levels-1; i >= 1; i--) {
        n_blocks_1 = dim3(w_iDivUp(Nc2/2, tpb), w_iDivUp(Nr2, tpb), 1);
        n_blocks_2 = dim3(w_iDivUp(Nc2, tpb), w_iDivUp(Nr2, tpb), 1);
        w_kern_inverse_pass1<<<n_blocks_1, n_threads_per_block>>>(d_coeffs[0], d_coeffs[3*i+1], d_coeffs[3*i+2], d_coeffs[3*i+3], d_tmp1, d_tmp2, Nr2/2, Nc2/2, hlen);
        w_kern_inverse_pass2<<<n_blocks_2, n_threads_per_block>>>(d_tmp1, d_tmp2, d_coeffs[0], Nr2, Nc2/2, hlen);
        Nr2 *= 2;
        Nc2 *= 2;
    }
    // First scale
    n_blocks_1 = dim3(w_iDivUp(Nc2/2, tpb), w_iDivUp(Nr2, tpb), 1);
    n_blocks_2 = dim3(w_iDivUp(Nc2, tpb), w_iDivUp(Nr2, tpb), 1);
    w_kern_inverse_pass1<<<n_blocks_1, n_threads_per_block>>>(d_coeffs[0], d_coeffs[1], d_coeffs[2], d_coeffs[3], d_tmp1, d_tmp2, Nr2/2, Nc2/2, hlen);
    w_kern_inverse_pass2<<<n_blocks_2, n_threads_per_block>>>(d_tmp1, d_tmp2, d_image, Nr2, Nc2/2, hlen);

    return 0;
}



/// ----------------------------------------------------------------------------
/// --------------------- Forward Undecimated DWT ------------------------------
/// ----------------------------------------------------------------------------



// must be run with grid size = (Nc, Nr)  where Nr = numrows of input image
// Pass 1 : Input image ==> horizontal convolution with L, H  ==> (tmp_a1, tmp_a2)
__global__ void w_kern_forward_swt_pass1(float* img, float* tmp_a1, float* tmp_a2, int Nr, int Nc, int hlen, int level) {
    int gidx = threadIdx.x + blockIdx.x*blockDim.x;
    int gidy = threadIdx.y + blockIdx.y*blockDim.y;
    if (gidy < Nr && gidx < Nc) {

        int factor = 1 << (level - 1);
        int c, hL, hR;
        if (hlen & 1) { // odd kernel size
            c = hlen/2;
            hL = c;
            hR = c;
        }
        else { // even kernel size : center is shifted to the left
            c = hlen/2 - 1;
            hL = c;
            hR = c+1;
        }

        c *= factor;
        int jx1 = c - gidx;
        int jx2 = Nc - 1 - gidx + c;
        float res_tmp_a1 = 0, res_tmp_a2 = 0;
        float img_val;

        // Convolution with periodic boundaries extension.
        // The filters are 2-upsampled at each level : [h0, h1, h2, h3] --> [h0, 0, h1, 0, h2, 0, h3, 0]
       for (int jx = 0; jx <= hR+hL; jx++) {
            int idx_x = gidx + jx*factor - c;
            if (factor*jx < jx1) idx_x += Nc;
            if (factor*jx > jx2) idx_x -= Nc;

            img_val = img[(gidy)*Nc + idx_x];
            res_tmp_a1 += img_val * c_kern_L[hlen-1 - jx];
            res_tmp_a2 += img_val * c_kern_H[hlen-1 - jx];
        }

        tmp_a1[gidy* Nc + gidx] = res_tmp_a1;
        tmp_a2[gidy* Nc + gidx] = res_tmp_a2;
    }
}

// must be run with grid size = (Nc, Nr)  where Nr = numrows of input image
// Pass 2 : (tmp_a1, tmp_a2) ==>  Vertic convolution on tmp_a1 and tmp_a2 with  L, H  ==> (a, h, v, d)
__global__ void w_kern_forward_swt_pass2(float* tmp_a1, float* tmp_a2, float* c_a, float* c_h, float* c_v, float* c_d, int Nr, int Nc, int hlen, int level) {
    int gidx = threadIdx.x + blockIdx.x*blockDim.x;
    int gidy = threadIdx.y + blockIdx.y*blockDim.y;
    if (gidy < Nr && gidx < Nc) {

        int factor = 1 << (level - 1);
        int c, hL, hR;
        if (hlen & 1) { // odd kernel size
            c = hlen/2;
            hL = c;
            hR = c;
        }
        else { // even kernel size : center is shifted to the left
            c = hlen/2 - 1;
            hL = c;
            hR = c+1;
        }

        c *= factor;
        int jy1 = c - gidy;
        int jy2 = Nr - 1 - gidy + c;
        float res_a = 0, res_h = 0, res_v = 0, res_d = 0;

        // Convolution with periodic boundaries extension.
        // The filters are 2-upsampled at each level : [h0, h1, h2, h3] --> [h0, 0, h1, 0, h2, 0, h3, 0]
        for (int jy = 0; jy <= hR+hL; jy++) {
            int idx_y = gidy + factor*jy - c;
            if (factor*jy < jy1) idx_y += Nr;
            if (factor*jy > jy2) idx_y -= Nr;

            res_a += tmp_a1[idx_y*Nc + gidx] * c_kern_L[hlen-1 - jy];
            res_h += tmp_a1[idx_y*Nc + gidx] * c_kern_H[hlen-1 - jy];
            res_v += tmp_a2[idx_y*Nc + gidx] * c_kern_L[hlen-1 - jy];
            res_d += tmp_a2[idx_y*Nc + gidx] * c_kern_H[hlen-1 - jy];
        }

        c_a[gidy* Nc + gidx] = res_a;
        c_h[gidy* Nc + gidx] = res_h;
        c_v[gidy* Nc + gidx] = res_v;
        c_d[gidy* Nc + gidx] = res_d;
    }
}


int w_forward_swt_separable(float* d_image, float** d_coeffs, float* d_tmp, int Nr, int Nc, int levels, int hlen) {

    //~ // DEBUG
    //~ float* d_tmp1, *d_tmp2;
    //~ cudaMalloc(&d_tmp1, Nr*Nc*sizeof(float));
    //~ cudaMalloc(&d_tmp2, Nr*Nc*sizeof(float));
    //~ puts("Performing forward SWT");
    //~ // ----


    float* d_tmp1 = d_tmp;
    float* d_tmp2 = d_tmp + Nr*Nc;

    int tpb = 16; // TODO : tune for max perfs.
    dim3 n_blocks_1 = dim3(w_iDivUp(Nc, tpb), w_iDivUp(Nr, tpb), 1);
    dim3 n_blocks_2 = dim3(w_iDivUp(Nc, tpb), w_iDivUp(Nr, tpb), 1);
    dim3 n_threads_per_block = dim3(tpb, tpb, 1);
    // First level
    w_kern_forward_swt_pass1<<<n_blocks_1, n_threads_per_block>>>(d_image, d_tmp1, d_tmp2, Nr, Nc, hlen, 1);
    w_kern_forward_swt_pass2<<<n_blocks_2, n_threads_per_block>>>(d_tmp1, d_tmp2, d_coeffs[0], d_coeffs[1], d_coeffs[2], d_coeffs[3], Nr, Nc, hlen, 1);
    // Other levels
    for (int i=1; i < levels; i++) {
        w_kern_forward_swt_pass1<<<n_blocks_1, n_threads_per_block>>>(d_coeffs[0], d_tmp1, d_tmp2, Nr, Nc, hlen, i+1);
        w_kern_forward_swt_pass2<<<n_blocks_2, n_threads_per_block>>>(d_tmp1, d_tmp2, d_coeffs[0], d_coeffs[3*i+1], d_coeffs[3*i+2], d_coeffs[3*i+3], Nr, Nc, hlen, i+1);
    }
    return 0;
}



/// ----------------------------------------------------------------------------
/// --------------------- Inverse Undecimated DWT ------------------------------
/// ----------------------------------------------------------------------------


// must be run with grid size = (Nc, Nr) ; Nr = numrows of input coefficients
// pass 1 : (a, h, v, d)  ==> Vertical convol with IL, IH  ==> (tmp1, tmp2)
__global__ void w_kern_inverse_swt_pass1(float* c_a, float* c_h, float* c_v, float* c_d, float* tmp1, float* tmp2, int Nr, int Nc, int hlen, int level) {
    int gidx = threadIdx.x + blockIdx.x*blockDim.x;
    int gidy = threadIdx.y + blockIdx.y*blockDim.y;
    if (gidy < Nr && gidx < Nc) { // vertic oversampling : Input (Nr, Nc) => Output (Nr*2, Nc)
        int c, hL, hR;
        int factor = 1 << (level - 1);
        if (hlen & 1) { // odd half-kernel size
            c = hlen/2;
            hL = c;
            hR = c;
        }
        else { // even half-kernel size : center is shifted to the RIGHT for reconstruction.
            c = hlen/2 - 0;
            hL = c;
            hR = c-1;
        }
        c *= factor;
        int jy1 = c - gidy;
        int jy2 = Nr - 1 - gidy + c;
        int offset_y = 1-(gidy & 1);
        offset_y = 0;

        float res_a = 0, res_h = 0, res_v = 0, res_d = 0;
        for (int jy = 0; jy <= hR+hL; jy++) {
            int idx_y = gidy - c + factor*jy;
            if (factor*jy < jy1) idx_y += Nr;
            if (factor*jy > jy2) idx_y -= Nr;

            res_a += c_a[idx_y*Nc + gidx] * c_kern_IL[hlen-1 - (jy + offset_y)]/2;
            res_h += c_h[idx_y*Nc + gidx] * c_kern_IH[hlen-1 - (jy + offset_y)]/2;
            res_v += c_v[idx_y*Nc + gidx] * c_kern_IL[hlen-1 - (jy + offset_y)]/2;
            res_d += c_d[idx_y*Nc + gidx] * c_kern_IH[hlen-1 - (jy + offset_y)]/2;
        }
        tmp1[gidy * Nc + gidx] = res_a + res_h;
        tmp2[gidy * Nc + gidx] = res_v + res_d;
    }
}

// must be run with grid size = (Nr, Nc) ; Nc = numcols of input coeffs.
// pass 2 : (tmp1, tmp2)  ==> Horiz convol with IL, IH  ==> I
__global__ void w_kern_inverse_swt_pass2(float* tmp1, float* tmp2, float* img, int Nr, int Nc, int hlen, int level) {
    int gidx = threadIdx.x + blockIdx.x*blockDim.x;
    int gidy = threadIdx.y + blockIdx.y*blockDim.y;
    if (gidy < Nr && gidx < Nc) { // horiz oversampling : Input (Nr*2, Nc) => Output (Nr*2, Nc*2)
        int c, hL, hR;
        int factor = 1 << (level - 1);
        if (hlen & 1) { // odd half-kernel size
            c = hlen/2;
            hL = c;
            hR = c;
        }
        else { // even half-kernel size : center is shifted to the RIGHT for reconstruction.
            c = hlen/2 - 0;
            hL = c;
            hR = c-1;
        }
        c *= factor;
        int jx1 = c - gidx;
        int jx2 = Nc - 1 - gidx + c;
        int offset_x = 1-(gidx & 1);
        offset_x = 0;

        float res_1 = 0, res_2 = 0;
        for (int jx = 0; jx <= hR+hL; jx++) {
            int idx_x = gidx - c + factor*jx;
            if (factor*jx < jx1) idx_x += Nc;
            if (factor*jx > jx2) idx_x -= Nc;

            res_1 += tmp1[gidy*Nc + idx_x] * c_kern_IL[hlen-1 - (jx + offset_x)]/2;
            res_2 += tmp2[gidy*Nc + idx_x] * c_kern_IH[hlen-1 - (jx + offset_x)]/2;
        }
        img[gidy * Nc + gidx] = res_1 + res_2;
    }
}


int w_inverse_swt_separable(float* d_image, float** d_coeffs, float* d_tmp, int Nr, int Nc, int levels, int hlen) {

    //~ // DEBUG
    //~ float* d_tmp1, *d_tmp2;
    //~ cudaMalloc(&d_tmp1, Nr*Nc*sizeof(float));
    //~ cudaMalloc(&d_tmp2, Nr*Nc*sizeof(float));
    //~ puts("Performing inverse SWT");
    //~ // ----

    float* d_tmp1 = d_tmp;
    float* d_tmp2 = d_tmp + Nr*Nc;

    int tpb = 16; // TODO : tune for max perfs.
    dim3 n_blocks_1 = dim3(w_iDivUp(Nc, tpb), w_iDivUp(Nr, tpb), 1);
    dim3 n_blocks_2 = dim3(w_iDivUp(Nc, tpb), w_iDivUp(Nr, tpb), 1);
    dim3 n_threads_per_block = dim3(tpb, tpb, 1);

    for (int i = levels-1; i >= 1; i--) {
        w_kern_inverse_swt_pass1<<<n_blocks_1, n_threads_per_block>>>(d_coeffs[0], d_coeffs[3*i+1], d_coeffs[3*i+2], d_coeffs[3*i+3], d_tmp1, d_tmp2, Nr, Nc, hlen, i+1);
        w_kern_inverse_swt_pass2<<<n_blocks_2, n_threads_per_block>>>(d_tmp1, d_tmp2, d_coeffs[0], Nr, Nc, hlen, i+1);
    }
    // First scale
    w_kern_inverse_swt_pass1<<<n_blocks_1, n_threads_per_block>>>(d_coeffs[0], d_coeffs[1], d_coeffs[2], d_coeffs[3], d_tmp1, d_tmp2, Nr, Nc, hlen, 1);
    w_kern_inverse_swt_pass2<<<n_blocks_2, n_threads_per_block>>>(d_tmp1, d_tmp2, d_image, Nr, Nc, hlen, 1);

    return 0;
}



