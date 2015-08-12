#ifndef RMD_SEED_UPDATE_CU
#define RMD_SEED_UPDATE_CU

#include <rmd/device_data.cuh>

#include "triangulation.cu"

namespace rmd
{

__device__ __forceinline__
float normpdf(
    const float &x,
    const float &mu,
    const float & sigma_sq)
{
  return (expf(-(x-mu)*(x-mu) / (2.0f*sigma_sq))) * rsqrtf(2.0f*M_PI*sigma_sq);
}

__global__
void seedUpdateKernel(
    DeviceData *dev_ptr,
    rmd::SE3<float> T_ref_curr)
{
  int x = blockIdx.x * blockDim.x + threadIdx.x;
  int y = blockIdx.y * blockDim.y + threadIdx.y;

  if(x >= dev_ptr->width || y >= dev_ptr->height)
    return;

  const float xx = x+0.5f;
  const float yy = y+0.5f;

  // Check convergence status of seed
  if( (ConvergenceStates::CONVERGED == tex2D(convergence_tex, xx, yy)) ||
      (ConvergenceStates::DIVERGED  == tex2D(convergence_tex, xx, yy)) )
    return;

  if( ConvergenceStates::UPDATE == tex2D(convergence_tex, xx, yy) )
  {
    // Bayesian update
    // Retrieve current estimations of parameters
    const float mu = tex2D(mu_tex, xx, yy);
    const float sigma_sq = tex2D(sigma_tex, xx, yy);
    const float a = tex2D(a_tex, xx, yy);
    const float b = tex2D(b_tex, xx, yy);

    // The pixel in reference frame
    const float2 px_ref = make_float2((float)x, (float)y);
    const float3 f_ref = normalize(dev_ptr->cam.cam2world(px_ref));
    // and the epipolar match
    const float2 epipolar_match = tex2D(epipolar_matches_tex, xx, yy);
    const float3 f_epi_match  = normalize(dev_ptr->cam.cam2world(epipolar_match));
    const float3 pt_xyz_ref = triangulatenNonLin(
          f_ref,
          f_epi_match,
          T_ref_curr);
    if(pt_xyz_ref.z < 0.0f)
    {
      return;
    }
    const float depth = norm(pt_xyz_ref);
    //float z = pt_xyz_ref.z;
    float tau = triangulationUncertainty(
          depth,
          f_ref,
          T_ref_curr.getTranslation(),
          dev_ptr->cam.getOnePixAngle());
    const float tau_sq = tau * tau;
    const float s_sq = (tau_sq * sigma_sq) / (tau_sq + sigma_sq);
    const float m    = s_sq * (mu / sigma_sq + depth / tau_sq);
    float c1   = (a / (a+b)) * normpdf(depth, mu, sigma_sq+tau_sq);
    float c2   = (b / (a+b)) * (1.0f / dev_ptr->scene.depth_range);
    const float norm_const = c1 + c2;
    c1 = c1 / norm_const;
    c2 = c2 / norm_const;
    const float f = c1 * ((a + 1.0f) / (a + b + 1.0f)) + c2 *(a / (a + b + 1.0f));
    const float e = c1 * (( (a + 1.0f)*(a + 2.0f)) / ((a + b + 1.0f) * (a + b + 2.0f))) +
        c2 *(a*(a + 1.0f) / ((a + b + 1.0f) * (a + b + 2.0f)));

    if(isnan(c1*m))
    {
      return;
    }

    const float mu_prime = c1 * m + c2 * mu;
    dev_ptr->sigma.data[y*dev_ptr->sigma.stride+x] =
        c1 *(s_sq + m*m) + c2 * (sigma_sq + mu*mu) - mu_prime*mu_prime;
    dev_ptr->mu.data[y*dev_ptr->mu.stride+x] = mu_prime;
    const float a_prime = ( e - f ) / ( f - e/f );
    dev_ptr->a.data[y*dev_ptr->a.stride+x] = a_prime;
    dev_ptr->b.data[y*dev_ptr->b.stride+x] = a_prime * ( 1.0f-f ) / f;
  }

  else if(ConvergenceStates::NO_MATCH == tex2D(convergence_tex, xx, yy))
  { // no match but projection inside the image: penalize the seed
    const float b = tex2D(b_tex, xx, yy) + 1.0f;
    dev_ptr->b.data[y*dev_ptr->b.stride+x] = b;
  }
  else if (ConvergenceStates::NOT_VISIBLE == tex2D(convergence_tex, xx, yy))
  { // no match, projection out of the image
  }
}

} // rmd namespace

#endif
