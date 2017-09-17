#include <cuda.h>
#include <cuda_runtime.h>
#include <iostream>
#include "common.h"
#include "efficient.h"

namespace StreamCompaction {
    namespace Efficient {
        using StreamCompaction::Common::PerformanceTimer;
        PerformanceTimer& timer()
        {
            static PerformanceTimer timer;
            return timer;
        }

        /**
         * Performs prefix-sum (aka scan) on idata, storing the result into odata.
         */
		__global__ void EfficientScanAlgorithm(int* idata, int* odata, int n, int step)
		{

			int index = (blockIdx.x * blockDim.x) + threadIdx.x;

			if ((index >= n) || (index < 0))
			{
				return;
			}
			if (index >= step)
			{
				odata[index] = idata[index - step] + idata[index];
			}
			else
			{
				odata[index] = idata[index];
			}

		}
        void scan(int n, int *odata, const int *idata) {
            timer().startGpuTimer();
            // TODO
			int blockSize = 256;
			dim3 fullBlocksPerGrid((n + blockSize - 1) / blockSize);
			const int memoryCopySize = n * sizeof(int);
			int step;

			//false means output is odata, true means output is idata
			//bool outAndInFlag = false;

			int* dev_idata;
			int* dev_odata;
			int* temp_odata;

			temp_odata = (int*)malloc(memoryCopySize);

			cudaMalloc((void**)&dev_idata, memoryCopySize);
			checkCUDAError("cudaMalloc dev_idata failed!");

			cudaMemcpy(dev_idata, idata, memoryCopySize, cudaMemcpyHostToDevice);
			checkCUDAError("cudaMemcpy idata to dev_idata failed!");

			cudaMalloc((void**)&dev_odata, memoryCopySize);
			checkCUDAError("cudaMalloc dev_odata failed!");

			for (int d = 1;d <= ilog2ceil(n);d++)
			{
				step = pow(2, d - 1);
				EfficientScanAlgorithm << <fullBlocksPerGrid, blockSize >> > (dev_idata, dev_odata, n, step);
				cudaThreadSynchronize();
				cudaMemcpy(dev_idata, dev_odata, memoryCopySize, cudaMemcpyDeviceToDevice);
				cudaDeviceSynchronize();
			}

			cudaMemcpy(temp_odata, dev_idata, memoryCopySize, cudaMemcpyDeviceToHost);
			cudaDeviceSynchronize();

			odata[0] = 0;
			for (int i = 1;i < n;i++)
			{
				odata[i] = temp_odata[i - 1];
			}

			cudaFree(dev_idata);
			cudaFree(dev_odata);

			free(temp_odata);
            timer().endGpuTimer();
        }


		__global__ void EfficientMappingAlgorithm(int n, int* idata, int * mappedData)
		{
			int index = (blockIdx.x * blockDim.x) + threadIdx.x;
			if ((index >= n) || (index < 0))
			{
				return;
			}
			mappedData[index] = 0;

			if (idata[index] != 0)
			{
				mappedData[index] = 1;
			}
		}


		__global__ void EfficientCompactAlgorithm(int n, int* idata, int *odata,int* mappedData,int* scannedData)
		{
			int index = (blockIdx.x * blockDim.x) + threadIdx.x;
			if ((index >= n) || (index < 0))
			{
				return;
			}

			if (mappedData[index] != 0)
			{
				int idx = scannedData[index];
				odata[idx] = idata[index];
			}
		}

		__global__ void ODataInitialize(int n, int*odata)
		{
			int index = (blockIdx.x * blockDim.x) + threadIdx.x;
			if ((index >= n) || (index < 0))
			{
				return;
			}

			odata[index] = -1;
		}

		__global__ void ScanDataTransfer(int* scannedDataIn, int* scannDataOut, int n)
		{
			int index = (blockIdx.x * blockDim.x) + threadIdx.x;
			if ((index >= n) || (index < 0))
			{
				return;
			}
			
			if (index == 0)
			{
				scannDataOut[index] = 0;
				return;
			}
			scannDataOut[index] = scannedDataIn[index - 1];
		}

        /**
         * Performs stream compaction on idata, storing the result into odata.
         * All zeroes are discarded.
         *
         * @param n      The number of elements in idata.
         * @param odata  The array into which to store elements.
         * @param idata  The array of elements to compact.
         * @returns      The number of elements remaining after compaction.
         */
        int compact(int n, int *odata, const int *idata) {
            timer().startGpuTimer();
            // TODO
			int blockSize = 256;
			dim3 fullBlocksPerGrid((n + blockSize - 1) / blockSize);
			const int memoryCopySize = n * sizeof(int);

			int step;

			int* scannedDataIn;
			int* scannedDataOut;
			int* mappedData;
			int* dev_odata;
			int* dev_idata;

			cudaMalloc((void**)&scannedDataIn, memoryCopySize);
			checkCUDAError("cudaMalloc scannedDataIn failed!");

			cudaMalloc((void**)&scannedDataOut, memoryCopySize);
			checkCUDAError("cudaMalloc scannedDataOut failed!");

			cudaMalloc((void**)&mappedData, memoryCopySize);
			checkCUDAError("cudaMalloc mappedData failed!");
			
			cudaMalloc((void**)&dev_odata, memoryCopySize);
			checkCUDAError("cudaMalloc dev_odata failed!");
			
			cudaMalloc((void**)&dev_idata, memoryCopySize);
			checkCUDAError("cudaMalloc dev_idata failed!");
			cudaMemcpy(dev_idata, idata, memoryCopySize, cudaMemcpyHostToDevice);
			checkCUDAError("cudaMemcpy dev_idata failed!");

			ODataInitialize << <fullBlocksPerGrid, blockSize >> >(n, dev_odata);
			cudaDeviceSynchronize();

			EfficientMappingAlgorithm << <fullBlocksPerGrid, blockSize >> > (n, dev_idata, mappedData);
			cudaDeviceSynchronize();

			cudaMemcpy(scannedDataIn, mappedData, memoryCopySize, cudaMemcpyDeviceToDevice);
			checkCUDAError("cudaMemcpy scannedDataIn failed!");

			for (int d = 1;d <= ilog2ceil(n);d++)
			{
				step = pow(2, d - 1);
				EfficientScanAlgorithm << <fullBlocksPerGrid, blockSize >> > (scannedDataIn, scannedDataOut, n, step);
				cudaThreadSynchronize();
				cudaMemcpy(scannedDataIn, scannedDataOut, memoryCopySize, cudaMemcpyDeviceToDevice);
				cudaDeviceSynchronize();
			}

			ScanDataTransfer << <fullBlocksPerGrid, blockSize >> >(scannedDataIn, scannedDataOut, n);
			cudaDeviceSynchronize();

			EfficientCompactAlgorithm << <fullBlocksPerGrid, blockSize >> > (n, dev_idata, dev_odata, mappedData, scannedDataOut);
			cudaThreadSynchronize();

			cudaMemcpy(odata, dev_odata, memoryCopySize, cudaMemcpyDeviceToHost);

			//for (int i = 0;i < 10; i++)
			//{
			//	std::cout << odata[i] << std::endl;
			//}

			int count = 0;
			int value = odata[count];

			while (value != -1) 
			{
				count++;
				value = odata[count];
			}

			cudaFree(scannedDataIn);
			cudaFree(scannedDataOut);
			cudaFree(dev_idata);
			cudaFree(dev_odata);
			cudaFree(mappedData);

            timer().endGpuTimer();
			return count;
        }
    }
}
