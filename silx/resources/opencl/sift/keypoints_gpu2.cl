/*
 *   Project: SIFT: An algorithm for image alignement
 *
 *   Copyright (C) 2013-2017 European Synchrotron Radiation Facility
 *                           Grenoble, France
 *
 *   Principal authors: J. Kieffer (kieffer@esrf.fr)
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */
/*

	Kernels for keypoints processing

	A *group of threads* handles one keypoint, for additional information is required in the keypoint neighborhood

	WARNING: local workgroup size must be at least 128 for orientation_assignment


	For descriptors (so far) :
	we use shared memory to store temporary 128-histogram (1 per keypoint)
	  therefore, we need 128*N*4 bytes for N keypoints. We have
	  -- 16 KB per multiprocessor for <=1.3 compute capability (GTX <= 295), that allows to process N<=30 keypoints per thread
	  -- 48 KB per multiprocessor for >=2.x compute capability (GTX >= 465, Quadro 4000), that allows to process N<=95 keypoints per thread


Those kernel are optimized for compute capability >=2.0 (generation Fermi and Kepler )

Mind to include sift.cl
*/

/* Deprecated:
typedef float4 keypoint;

Defined in sift.cl
typedef struct actual_keypoint
{
    float col, row, scale, angle;
} actual_keypoint;
*/

#ifndef WORKGROUP_SIZE
	#define WORKGROUP_SIZE 128
#endif


/*
 *
 * \brief Compute a SIFT descriptor for each keypoint.
 *		WARNING: THE WORKGROUP SIZE MUST BE (8,8,8) -- see below for explanations
 *
 *
 * Like in sift.cpp, keypoints are eventually cast to 1-byte integer, for memory sake.
 * However, calculations need to be on float, so we need a temporary descriptors vector in shared memory.
 *
 *		We have to examine the [-iradius,iradius]^2 zone, maximum [-43,43]^2
 *	To the next power of two, this is a 128*128 zone. Hence, we cannot use one thread per pixel.
 *		Like in SIFT, we divide the patch in 4x4 subregions, each being handled by one thread.
 *	This is, one thread handles at most 32x32=1024 pixels.	
 *	For memory, we take 16x16=256 pixels per thread, so we can use a 2D shared memory (32*32*4=4096).
 *		Additionally, a third dimension in the workgroup (size 8) enables coalesced memory access and more paralellization.
 *
 *
 * :param keypoints: Pointer to global memory with current keypoints vector
 * :param descriptor: Pointer to global memory with the output SIFT descriptor, cast to uint8
 * :param grad: Pointer to global memory with gradient norm previously calculated
 * :param orim: Pointer to global memory with gradient orientation previously calculated
 * :param octsize: the size of the current octave (1, 2, 4, 8...)
 * :param keypoints_start : index start for keypoints
 * :param keypoints_end: end index for keypoints
 * :param grad_width: integer number of columns of the gradient
 * :param grad_height: integer num of lines of the gradient


-par.MagFactor = 3 //"1.5 sigma"
-OriSize  = 8 //number of bins in the local histogram
-par.IndexSigma  = 1.0

 */



kernel void descriptor(
	global actual_keypoint* keypoints,
	global uchar *descriptors,
	global float* grad,
	global float* orim,
	int octsize,
	int keypoints_start,
//	int keypoints_end,
	global int* keypoints_end, //passing counter value to avoid to read it each time
	int grad_width,
	int grad_height)
{

	int lid0 = get_local_id(0); //[0,8[
	int lid1 = get_local_id(1); //[0,8[
	int lid2 = get_local_id(2); //[0,8[
	int lid = (lid0*8+lid1)*8+lid2; //[0,512[ to limit to [0,128[
	int groupid = get_group_id(0);
	actual_keypoint kp = keypoints[groupid];
	if (!(keypoints_start <= groupid && groupid < *keypoints_end && kp.row >=0.0f))
		return;

	int i,j,j2;
	
	local volatile float histogram[128];		//for "final" histogram
	local volatile float hist2[128];		   //for temporary histogram
	local volatile unsigned int hist3[128*8]; //for the atomic_add
	
	float rx, cx,
	      one_octsize = 1.0f/octsize,
	      row = kp.row*one_octsize,
	      col = kp.col*one_octsize,
	      sine = sin(kp.angle),
	      cosine = cos(kp.angle),
	      spacing = kp.scale*one_octsize * 3.0f;
	int	irow = (int) (row + 0.5f),
	    icol = (int) (col + 0.5f),
	    radius = (int) ((1.414f * spacing * 2.5f) + 0.5f),
	    imin = -64 +16*lid1,
		jmin = -64 +16*lid2,
	    imax = imin+16,
		jmax = jmin+16;
		
	//memset
	for (i=0; i < 2; i++) {
		hist3[i*512+lid] = 0;
	}
	if (lid < 128) {
		histogram[lid] = 0.0f;
	hist2[lid] = 0.0f;
	}
	for (i=imin; i < imax; i++) {
		for (j2=jmin/8; j2 < jmax/8; j2++) {	
			j=j2*8+lid0;
			rx = ((cosine * i - sine * j) - (row - irow)) / spacing + 1.5f;
			cx = ((sine * i + cosine * j) - (col - icol)) / spacing + 1.5f;

			if ((rx > -1.0f && rx < 4.0f && cx > -1.0f && cx < 4.0f
				 && (irow +i) >= 0  && (irow +i) < grad_height && (icol+j) >= 0 && (icol+j) < grad_width)) {

				float mag = grad[icol+j + (irow+i)*grad_width]
							 * exp(- 0.125f*((rx - 1.5f) * (rx - 1.5f) + (cx - 1.5f) * (cx - 1.5f)) );
				float ori = orim[icol+j+(irow+i)*grad_width] -  kp.angle;
				while (ori > 2.0f*M_PI_F) ori -= 2.0f*M_PI_F;
				while (ori < 0.0f) ori += 2.0f*M_PI_F;
				int	orr, rindex, cindex, oindex;
				float	rweight, cweight;
				float oval = 4.0f*ori*M_1_PI_F;

				int	ri = (int)((rx >= 0.0f) ? rx : rx - 1.0f),
					ci = (int)((cx >= 0.0f) ? cx : cx - 1.0f),
					oi = (int)((oval >= 0.0f) ? oval : oval - 1.0f);

				float rfrac = rx - ri,
					cfrac = cx - ci,
					ofrac = oval - oi;
				if ((ri >= -1  &&  ri < 4  && oi >=  0  &&  oi <= 8  && rfrac >= 0.0f  &&  rfrac <= 1.0f)) {
					for (int r = 0; r < 2; r++) {
						rindex = ri + r;
						if ((rindex >=0 && rindex < 4)) {
							rweight = mag * ((r == 0) ? 1.0f - rfrac : rfrac);

							for (int c = 0; c < 2; c++) {
								cindex = ci + c;
								if ((cindex >=0 && cindex < 4)) {
									cweight = rweight * ((c == 0) ? 1.0f - cfrac : cfrac);
									for (orr = 0; orr < 2; orr++) {
										oindex = oi + orr;
										if (oindex >= 8) {  /* Orientation wraps around at PI. */
											oindex = 0;
										}
										int bin = (rindex*4 + cindex)*8+oindex; //value in [0,128[
										
//										hist2[8*bin+lid0] += cweight * ((orr == 0) ? 1.0f - ofrac : ofrac);
										
										//we do not have atomic_add on floats, but we know the upper limit of this float
										//take its 5 first (decimal) digits
										atomic_add(hist3+bin*8+lid0,
											(unsigned int) (100000*(cweight * ((orr == 0) ? 1.0f - ofrac : ofrac))));
									
										
									} //end "for orr"
								} //end "valid cindex"
							} //end "for c"
						} //end "valid rindex"
					} //end "for r"
					
					
				}
			}//end "in the boundaries"
		} //end j loop
	}//end i loop
	
/*
	barrier(CLK_LOCAL_MEM_FENCE);
	if (lid < 128)
		histogram[lid] 
			+= hist2[lid*8]+hist2[lid*8+1]+hist2[lid*8+2]+hist2[lid*8+3]
			+hist2[lid*8+4]+hist2[lid*8+5]+hist2[lid*8+6]+hist2[lid*8+7];
*/

	barrier(CLK_LOCAL_MEM_FENCE);
	if (lid < 128)
		histogram[lid] 
			+= (float) ((hist3[lid*8]+hist3[lid*8+1]+hist3[lid*8+2]+hist3[lid*8+3]
			+hist3[lid*8+4]+hist3[lid*8+5]+hist3[lid*8+6]+hist3[lid*8+7])*0.00001f);



	barrier(CLK_LOCAL_MEM_FENCE);

	//memset of 128 values of hist2 before re-use
	if (lid < 128) hist2[lid] = histogram[lid]*histogram[lid];
	
	/*
	 	Normalization and thre work shared by the 16 threads (8 values per thread)
	*/
	
	//parallel reduction to normalize vector

	if (lid < 64) {
		hist2[lid] += hist2[lid+64];
	}
	barrier(CLK_LOCAL_MEM_FENCE);
	if (lid < 32) {
		hist2[lid] += hist2[lid+32];
	}

	barrier(CLK_LOCAL_MEM_FENCE);
	if (lid < 16) {
		hist2[lid] += hist2[lid+16];
	}
	barrier(CLK_LOCAL_MEM_FENCE);
	if (lid < 8) {
		hist2[lid] += hist2[lid+8];
	}
	barrier(CLK_LOCAL_MEM_FENCE);
	if (lid < 4) {
		hist2[lid] += hist2[lid+4];
	}
	barrier(CLK_LOCAL_MEM_FENCE);
	if (lid < 2) {
		hist2[lid] += hist2[lid+2];
	}
	barrier(CLK_LOCAL_MEM_FENCE);
	if (lid == 0) hist2[0] = rsqrt(hist2[1]+hist2[0]);
	barrier(CLK_LOCAL_MEM_FENCE);
	//now we have hist2[0] = 1/sqrt(sum(hist[i]^2))
	
	if (lid < 128) {
		histogram[lid] *= hist2[0];

		//Threshold to 0.2 of the norm, for invariance to illumination
		__local int changed[1];
		if (lid == 0) changed[0] = 0;
		if (histogram[lid] > 0.2f) {
			histogram[lid] = 0.2f;
			atomic_inc(changed);
		}
		barrier(CLK_LOCAL_MEM_FENCE);
		//if values have changed, we have to re-normalize
		if (changed[0]) { 
			hist2[lid] = histogram[lid]*histogram[lid];
			if (lid < 64) {
				hist2[lid] += hist2[lid+64];
			}
			barrier(CLK_LOCAL_MEM_FENCE);
			if (lid < 32) {
				hist2[lid] += hist2[lid+32];
			}
			barrier(CLK_LOCAL_MEM_FENCE);
			if (lid < 16) {
				hist2[lid] += hist2[lid+16];
			}
			barrier(CLK_LOCAL_MEM_FENCE);
			if (lid < 8) {
				hist2[lid] += hist2[lid+8];
			}
			barrier(CLK_LOCAL_MEM_FENCE);
			if (lid < 4) {
				hist2[lid] += hist2[lid+4];
			}
			barrier(CLK_LOCAL_MEM_FENCE);
			if (lid < 2) {
				hist2[lid] += hist2[lid+2];
			}
			barrier(CLK_LOCAL_MEM_FENCE);
			if (lid == 0) hist2[0] = rsqrt(hist2[0]+hist2[1]);
			barrier(CLK_LOCAL_MEM_FENCE);
			histogram[lid] *= hist2[0];
		}
		
		barrier(CLK_LOCAL_MEM_FENCE);
		//finally, cast to integer
	    int intval =  (int)(512.0f * histogram[lid]);
		descriptors[128*groupid+lid] = (uchar) min(255, intval);
	} //end "if lid < 128"
}






