# Foundational Architecture Papers for Unified Multimodal Models

**Purpose:** Reading list of essential papers that underpin the architectures of modern unified multimodal understanding and generation models.

**Generated:** February 2026

---

## Executive Summary

This document identifies 15 foundational architectural innovations that power current unified multimodal models, tracing each back to its original paper. The papers are organized by importance tier and category to guide your reading.

**Must-Read Papers (Tier 1):** 8 papers - essential for understanding the field
**Important Papers (Tier 2):** 4 papers - significant for specific approaches
**Specialized Papers (Tier 3):** 3 papers - valuable for specific use cases

---

## Tier 1: Must-Read Foundational Papers

These papers introduced concepts that are now ubiquitous across unified multimodal architectures.

### 1. Diffusion Transformers (DiT) - THE Backbone
**Paper:** Scalable Diffusion Models with Transformers  
**Authors:** William Peebles, Saining Xie  
**Year:** 2022/2023 (ICCV 2023 Oral)  
**ArXiv:** [2212.09748](https://arxiv.org/abs/2212.09748)  
**Used By:** Nexus-Gen, OmniGen2, UniWorld-V1, Qwen-Image

**Why Critical:**
- Replaced U-Net as the standard diffusion backbone
- Enabled scaling diffusion models to transformer sizes
- Foundation for all modern diffusion-based unified models
- Demonstrated transformers can outperform CNNs for diffusion

**Key Innovation:** Operates on latent patches using standard transformer blocks instead of U-Net convolutions. Higher Gflops directly correlate with lower FID.

**Reading Priority:** HIGHEST - Essential for understanding modern diffusion architectures

---

### 2. Flow Matching - Training Method
**Paper:** Flow Matching for Generative Modeling  
**Authors:** Yaron Lipman, Ricky T. Q. Chen, Heli Ben-Hamu, et al.  
**Year:** 2022  
**ArXiv:** [2210.02747](https://arxiv.org/abs/2210.02747)  
**Used By:** BLIP3-o, Show-o2, NextStep-1, UniWorld-V1, BAGEL

**Why Critical:**
- Superior to DDPM for training diffusion models
- More stable training dynamics
- Compatible with general probability paths (not just diffusion)
- Now standard in state-of-the-art models

**Key Innovation:** Simulation-free training of Continuous Normalizing Flows by regressing vector fields. Subsumes diffusion as a special case while enabling more efficient paths like Optimal Transport.

**Reading Priority:** HIGHEST - Essential for understanding modern training methods

---

### 3. MMDiT - Multimodal Architecture
**Paper:** Scaling Rectified Flow Transformers for High-Resolution Image Synthesis  
**Authors:** Patrick Esser, Sumith Kulal, Andreas Blattmann, et al. (Stability AI)  
**Year:** 2024  
**ArXiv:** [2403.03206](https://arxiv.org/abs/2403.03206)  
**Used By:** Qwen-Image, Stable Diffusion 3, FLUX derivatives

**Why Critical:**
- Introduced separate weights for image and text modalities
- Bidirectional information flow between modalities
- Foundation of SD3 and FLUX architectures
- State-of-the-art text rendering capabilities

**Key Innovation:** Concatenates image and text tokens and processes via joint self-attention while maintaining separate parameter spaces for each modality.

**Reading Priority:** HIGHEST - Essential for multimodal architecture design

---

### 4. VQ-VAE - Discrete Tokenization
**Paper:** Neural Discrete Representation Learning  
**Authors:** Aaron van den Oord, Oriol Vinyals, Koray Kavukcuoglu  
**Year:** 2017 (NeurIPS 2017)  
**ArXiv:** [1711.00937](https://arxiv.org/abs/1711.00937)  
**Used By:** Chameleon, Janus, Emu3, LWM, Show-o

**Why Critical:**
- Foundation of discrete image tokenization
- Enables LLM-style next-token prediction for images
- Still widely used despite continuous alternatives
- Concept of learned codebooks is fundamental

**Key Innovation:** Uses vector quantization to learn discrete representations that avoid "posterior collapse" in VAEs. Encoder outputs discrete codes; decoder reconstructs from codebook embeddings.

**Reading Priority:** HIGH - Essential for understanding discrete approaches

**Also Read:** Taming Transformers for High-Resolution Image Synthesis (VQGAN, 2020) - [2012.09841](https://arxiv.org/abs/2012.09841)

---

### 5. SigLIP - Vision Encoder
**Paper:** Sigmoid Loss for Language Image Pre-Training  
**Authors:** Xiaohua Zhai, Basil Mustafa, Alexander Kolesnikov, et al.  
**Year:** 2023  
**ArXiv:** [2303.15343](https://arxiv.org/abs/2303.15343)  
**Used By:** Janus, UniWorld-V1, BAGEL, MetaQuery, OmniGen2

**Why Critical:**
- Standard vision encoder for modern unified models
- Replaces CLIP in most recent architectures
- Scales better to large batch sizes
- Superior semantic representations

**Key Innovation:** Pairwise sigmoid loss operates on image-text pairs without global softmax normalization. Enables scaling to batch sizes up to 1 million.

**Reading Priority:** HIGH - Essential for understanding vision encoders

---

### 6. RingAttention - Long Context
**Paper:** Ring Attention with Blockwise Transformers for Near-Infinite Context  
**Authors:** Hao Liu, Matei Zaharia, Pieter Abbeel  
**Year:** 2023  
**ArXiv:** [2310.01889](https://arxiv.org/abs/2310.01889)  
**Used By:** LWM, any model needing >100K context

**Why Critical:**
- Enables million-token contexts
- Overlaps communication with computation
- Distributed training without approximation
- Essential for video and long-document understanding

**Key Innovation:** Blockwise computation of self-attention distributes long sequences across devices while overlapping key-value block communication with computation.

**Reading Priority:** HIGH - Critical for long-context applications

---

### 7. Mixture-of-Experts (MoE) - Scaling
**Paper:** Outrageously Large Neural Networks: The Sparsely-Gated Mixture-of-Experts Layer  
**Authors:** Noam Shazeer, Azalia Mirhoseini, Krzysztof Maziarz, et al.  
**Year:** 2017  
**ArXiv:** [1701.06538](https://arxiv.org/abs/1701.06538)  
**Used By:** BAGEL (MoT variant), GPT-4, Mixtral

**Why Critical:**
- Foundation for scaling models beyond dense parameter limits
- Enables 10-100x parameter scaling with minimal compute overhead
- BAGEL's Mixture-of-Transformer-Experts builds on this
- Standard technique in production models

**Key Innovation:** Sparsely-gated MoE layer with trainable gating network that selects subset of experts per input. Achieves massive model capacity with sub-linear compute scaling.

**Reading Priority:** HIGH - Critical for scaling architectures

---

### 8. LoRA - Efficient Adaptation
**Paper:** LoRA: Low-Rank Adaptation of Large Language Models  
**Authors:** Edward J. Hu, Yelong Shen, Phillip Wallis, et al.  
**Year:** 2021 (ICLR 2022)  
**ArXiv:** [2106.09685](https://arxiv.org/abs/2106.09685)  
**Used By:** MetaQuery-style approaches, parameter-efficient fine-tuning

**Why Critical:**
- 10,000x reduction in trainable parameters
- Enables fine-tuning on consumer hardware
- No inference latency overhead
- Foundation of efficient adaptation strategies

**Key Innovation:** Injects trainable rank decomposition matrices into each transformer layer while freezing pre-trained weights. Low-rank updates approximate full fine-tuning.

**Reading Priority:** HIGH - Essential for practical deployment

---

## Tier 2: Important Specialized Papers

### 9. Rectified Flow - Efficient Sampling
**Paper:** Flow Straight and Fast: Learning to Generate and Transfer Data with Rectified Flow  
**Authors:** Xingchao Liu, Chengyue Gong, Qiang Liu  
**Year:** 2022  
**ArXiv:** [2209.03003](https://arxiv.org/abs/2209.03003)  
**Used By:** OmniGen2, some Flow Matching implementations

**Why Important:**
- Enables single-step generation (extreme efficiency)
- Straight paths through probability space
- Complementary to Flow Matching
- Increasingly used for fast inference

**Key Innovation:** Neural ODE models that follow straight paths between distributions by solving nonlinear least squares. Allows simulation without time discretization error.

**Reading Priority:** MEDIUM - Important for efficient inference

---

### 10. Grouped Query Attention - Memory Efficiency
**Paper:** GQA: Training Generalized Multi-Query Transformer Models from Multi-Head Checkpoints  
**Authors:** Joshua Ainslie, James Lee-Thorp, Michiel de Jong, et al.  
**Year:** 2023  
**ArXiv:** [2305.13245](https://arxiv.org/abs/2305.13245)  
**Used By:** BAGEL, Llama 2/3, modern LLMs

**Why Important:**
- Reduces KV cache memory by ~50%
- Maintains quality close to full multi-head attention
- Standard in production LLMs
- Critical for long-context efficiency

**Key Innovation:** Intermediate number of key-value heads (between 1 and query heads) balances memory efficiency of MQA with quality of multi-head attention.

**Reading Priority:** MEDIUM - Important for efficient inference

---

### 11. 3D Causal VAE - Video Tokenization
**Paper:** High-Quality Joint Image and Video Tokenization with Causal VAE  
**Authors:** Dawit Mureja Argaw, Xian Liu, Qinsheng Zhang, et al.  
**Year:** 2025 (ICLR 2025)  
**Conference:** [OpenReview](https://openreview.net/forum?id=aRD1NqcXTC)  
**Used By:** Show-o2, video generation models

**Why Important:**
- Unified space for images AND videos
- Causal convolution enables efficient video modeling
- Critical for video understanding/generation
- Foundation of next-gen video models

**Key Innovation:** Causal 3D convolution handles images and videos jointly with scale-agnostic encoder, novel spatio-temporal blocks, and flow regularization loss.

**Reading Priority:** MEDIUM - Essential for video applications

---

### 12. QK-Norm - Training Stability
**Paper:** Query-Key Normalization for Transformers  
**Authors:** Alex Henry, Prudhvi Raj Dachapally, Shubham Pawar, et al.  
**Year:** 2020  
**ArXiv:** [2010.04245](https://arxiv.org/abs/2010.04245)  
**Used By:** Show-o, Show-o2, many multimodal transformers

**Why Important:**
- Prevents softmax saturation
- Critical for training stability in multimodal models
- Minimal computational overhead
- Widely used in practice

**Key Innovation:** L2 normalization of queries and keys before attention, scaled by learnable parameter instead of dividing by sqrt(dim).

**Reading Priority:** MEDIUM - Important for training stability

---

## Tier 3: Specialized Innovations

### 13. MetaQueries - Frozen Backbone Generation
**Paper:** Transfer between Modalities with MetaQueries  
**Authors:** Xichen Pan, Satya Narayan Shukla, Aashu Singh, et al.  
**Year:** 2025  
**ArXiv:** [2504.06256](https://arxiv.org/abs/2504.06256)  
**Used By:** MetaQuery (original)

**Why Valuable:**
- Enables generation with frozen understanding models
- Minimal training requirements
- Preserves pretrained capabilities
- Efficient deployment strategy

**Key Innovation:** Learnable query tokens act as interface between frozen MLLM and diffusion decoder, extracting generation conditions without fine-tuning backbone.

**Reading Priority:** LOW-MEDIUM - Valuable for efficient deployment

---

### 14. Prefilled Autoregression - Error Mitigation
**Paper:** Nexus-Gen: Unified Image Understanding, Generation, and Editing via Prefilled Autoregression in Shared Embedding Space  
**Authors:** Hong Zhang, Zhongjie Duan, Xingjun Wang, et al.  
**Year:** 2025  
**ArXiv:** [2504.21356](https://arxiv.org/abs/2504.21356)  
**Used By:** Nexus-Gen (original)

**Why Valuable:**
- Solves error accumulation in AR embedding prediction
- Novel approach to training-inference alignment
- Specific to serial AR+Diffusion architectures

**Key Innovation:** Prefills input sequences with learnable embeddings (position-embedded special tokens) instead of predicting continuous embeddings directly.

**Reading Priority:** LOW - Specific to certain architectures

---

### 15. Transfusion - Unified Training
**Paper:** Transfusion: Predict the Next Token and Diffuse Images with One Multi-Modal Model  
**Authors:** Chunting Zhou, Lili Yu, Arun Babu, et al. (Meta AI)  
**Year:** 2024 (ICLR 2025 Oral)  
**ArXiv:** [2408.11039](https://arxiv.org/abs/2408.11039)  
**Used By:** Transfusion (original), LMFusion

**Why Valuable:**
- First successful AR+Diffusion unification
- Dual loss training methodology
- Proved concept of single-model multimodal training
- Foundation for single-model approaches

**Key Innovation:** Combines language modeling loss (cross-entropy) with diffusion loss (MSE) in single transformer. Different attention patterns for text (causal) vs images (bidirectional).

**Reading Priority:** LOW - Historical importance, though methods evolved

---

## Reading Schedule Recommendation

### Week 1: Core Concepts
1. **Day 1-2:** VQ-VAE (Neural Discrete Representation Learning)
2. **Day 3-4:** SigLIP (Sigmoid Loss for Language Image Pre-Training)
3. **Day 5-7:** DiT (Scalable Diffusion Models with Transformers)

### Week 2: Advanced Architectures
4. **Day 8-9:** MMDiT (Scaling Rectified Flow Transformers)
5. **Day 10-11:** Flow Matching (Flow Matching for Generative Modeling)
6. **Day 12-14:** RingAttention (Ring Attention with Blockwise Transformers)

### Week 3: Efficiency & Scaling
7. **Day 15-16:** MoE (Outrageously Large Neural Networks)
8. **Day 17-18:** LoRA (Low-Rank Adaptation)
9. **Day 19-21:** GQA + QK-Norm (Grouped Query Attention, Query-Key Normalization)

### Week 4: Specialized Topics
10. **Day 22-23:** Rectified Flow (Flow Straight and Fast)
11. **Day 24-25:** 3D Causal VAE (Joint Image and Video Tokenization)
12. **Day 26-28:** Recent innovations (MetaQueries, Prefilled Autoregression, Transfusion)

---

## Categorized by Architecture Component

### Image Tokenization
- **Discrete:** VQ-VAE (2017), VQGAN (2020)
- **Continuous:** 3D Causal VAE (2025)
- **Semantic:** SigLIP (2023)

### Diffusion Backbones
- **U-Net replacement:** DiT (2022)
- **Multimodal:** MMDiT (2024)
- **Efficiency:** GQA (2023)

### Training Methods
- **Standard:** Flow Matching (2022)
- **Fast inference:** Rectified Flow (2022)
- **Unified:** Transfusion (2024)
- **Stable:** QK-Norm (2020)

### Scaling & Efficiency
- **Parameter scaling:** MoE (2017)
- **Long context:** RingAttention (2023)
- **Efficient adaptation:** LoRA (2021)

### Specialized Techniques
- **Frozen backbone:** MetaQueries (2025)
- **Error mitigation:** Prefilled Autoregression (2025)

---

## Key Takeaways

1. **DiT + Flow Matching + MMDiT** form the current SOTA foundation
2. **SigLIP** has largely replaced CLIP for vision encoding
3. **Discrete vs Continuous** tokenization remains an open trade-off
4. **RingAttention** enables the long-context capabilities needed for video
5. **MoE and GQA** are essential for scaling to production sizes
6. **LoRA** enables practical fine-tuning and deployment

---

*Document compiled from research on 23+ unified multimodal models and their architectural foundations.*
