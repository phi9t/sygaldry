# Architecture Papers Follow-Up Tracker

**Objective:** Track reading and implementation of foundational papers for unified multimodal models

**Created:** February 2026

---

## Reading Progress

### Tier 1: Must Read (Complete First)

- [ ] **1. DiT - Diffusion Transformers**
  - Paper: arXiv:2212.09748
  - Authors: Peebles & Xie
  - Time: 2-3 hours
  - Key Code: https://github.com/facebookresearch/DiT
  - Notes: ___________________

- [ ] **2. Flow Matching**
  - Paper: arXiv:2210.02747  
  - Authors: Lipman et al.
  - Time: 3-4 hours
  - Key Code: https://github.com/facebookresearch/flow_matching
  - Notes: ___________________

- [ ] **3. MMDiT / Stable Diffusion 3**
  - Paper: arXiv:2403.03206
  - Authors: Esser et al. (Stability AI)
  - Time: 2-3 hours
  - Key Code: https://github.com/Stability-AI/sd3.5
  - Notes: ___________________

- [ ] **4. VQ-VAE**
  - Paper: arXiv:1711.00937
  - Authors: van den Oord et al.
  - Time: 2 hours
  - Key Code: https://github.com/deepmind/sonnet/blob/master/sonnet/python/modules/nets/vqvae.py
  - Notes: ___________________

- [ ] **5. SigLIP**
  - Paper: arXiv:2303.15343
  - Authors: Zhai et al. (Google)
  - Time: 2 hours
  - Key Code: https://github.com/google-research/scenic/tree/main/scenic/projects/siglip
  - Notes: ___________________

- [ ] **6. RingAttention**
  - Paper: arXiv:2310.01889
  - Authors: Liu et al. (Berkeley)
  - Time: 3-4 hours
  - Key Code: https://github.com/lhao499/RingAttention
  - Notes: ___________________

- [ ] **7. Mixture-of-Experts (MoE)**
  - Paper: arXiv:1701.06538
  - Authors: Shazeer et al. (Google)
  - Time: 2-3 hours
  - Key Code: https://github.com/tensorflow/mesh (original)
  - Notes: ___________________

- [ ] **8. LoRA**
  - Paper: arXiv:2106.09685
  - Authors: Hu et al. (Microsoft)
  - Time: 1-2 hours
  - Key Code: https://github.com/microsoft/LoRA
  - Notes: ___________________

**Tier 1 Completion Target:** ___________

---

### Tier 2: Important (Read After Tier 1)

- [ ] **9. Rectified Flow**
  - Paper: arXiv:2209.03003
  - Authors: Liu et al.
  - Time: 2-3 hours
  - Key Code: https://github.com/gnobitab/rectified-flow
  - Notes: ___________________

- [ ] **10. Grouped Query Attention (GQA)**
  - Paper: arXiv:2305.13245
  - Authors: Ainslie et al. (Google)
  - Time: 1-2 hours
  - Notes: ___________________

- [ ] **11. 3D Causal VAE**
  - Paper: ICLR 2025
  - Authors: Argaw et al.
  - Time: 2-3 hours
  - Notes: ___________________

- [ ] **12. QK-Norm**
  - Paper: arXiv:2010.04245
  - Authors: Henry et al.
  - Time: 1 hour
  - Notes: ___________________

**Tier 2 Completion Target:** ___________

---

### Tier 3: Specialized (Read as Needed)

- [ ] **13. MetaQueries**
  - Paper: arXiv:2504.06256
  - Authors: Pan et al. (Meta)
  - Time: 1-2 hours
  - Key Code: https://github.com/facebookresearch/metaquery
  - Notes: ___________________

- [ ] **14. Prefilled Autoregression**
  - Paper: arXiv:2504.21356
  - Authors: Zhang et al.
  - Time: 1-2 hours
  - Key Code: https://github.com/modelscope/Nexus-Gen
  - Notes: ___________________

- [ ] **15. Transfusion**
  - Paper: arXiv:2408.11039
  - Authors: Zhou et al. (Meta)
  - Time: 2 hours
  - Notes: ___________________

**Tier 3 Completion Target:** ___________

---

## Implementation Checklist

### Experiments to Run

**Week 1: Tokenization**
- [ ] Implement VQ-VAE from scratch
- [ ] Train on CIFAR-10 or ImageNet subset
- [ ] Compare reconstruction quality vs VAE
- [ ] Measure codebook usage

**Week 2: Diffusion**
- [ ] Implement DiT architecture
- [ ] Train on MNIST or CIFAR-10
- [ ] Compare vs U-Net baseline
- [ ] Ablate number of transformer blocks

**Week 3: Flow Matching**
- [ ] Implement Flow Matching training
- [ ] Compare convergence vs DDPM
- [ ] Test different probability paths (OT vs diffusion)
- [ ] Measure inference speed

**Week 4: Multimodal**
- [ ] Implement MMDiT-style dual-stream attention
- [ ] Test on simple text-to-image task
- [ ] Ablate separate vs shared weights
- [ ] Measure text adherence

---

## Key Implementation Resources

### Official Repositories

| Paper | Official Code | Community Reimplementations |
|-------|---------------|----------------------------|
| DiT | https://github.com/facebookresearch/DiT | lucidrains/dit-pytorch |
| Flow Matching | https://github.com/facebookresearch/flow_matching | torchcfm, flowmatching |
| SD3/MMDiT | https://github.com/Stability-AI/sd3.5 | diffusers |
| SigLIP | https://github.com/google-research/scenic | huggingface/transformers |
| RingAttention | https://github.com/lhao499/RingAttention | N/A |
| LoRA | https://github.com/microsoft/LoRA | huggingface/peft |

### Recommended Reading Order for Implementation

1. **Start Here:** LoRA (simplest, most practical)
2. **Then:** VQ-VAE (understand tokenization)
3. **Next:** DiT (understand diffusion backbone)
4. **Then:** Flow Matching (modern training)
5. **Finally:** MMDiT (put it all together)

---

## Quick Reference Cards

### DiT Key Points
```
- Replaces U-Net with Transformer
- Operates on latent patches
- Scales with compute (more Gflops = better FID)
- Standard transformer blocks
```

### Flow Matching Key Points
```
- Simulation-free CNF training
- Regresses vector fields
- General probability paths (not just diffusion)
- Optimal Transport paths are efficient
```

### MMDiT Key Points
```
- Separate weights for image/text
- Bidirectional attention
- Concatenate tokens from both modalities
- Foundation of SD3/FLUX
```

### RingAttention Key Points
```
- Blockwise attention computation
- Overlaps communication with compute
- Enables million-token contexts
- Distributed across devices
```

---

## Implementation Pitfalls to Avoid

### Common Mistakes

1. **VQ-VAE:** Not using EMA for codebook updates → poor reconstruction
2. **DiT:** Wrong patch size → memory issues or poor quality
3. **Flow Matching:** Wrong probability path → unstable training
4. **RingAttention:** Not overlapping communication → no speedup
5. **LoRA:** Wrong rank → underfitting or no speed benefit

### Debugging Checklist

- [ ] Codebook perplexity > 50 (VQ-VAE)
- [ ] Attention weights sum to ~1 (DiT)
- [ ] Vector field norm reasonable (Flow Matching)
- [ ] Memory usage scales linearly with sequence length (RingAttention)
- [ ] Trainable parameters reduced by 10-1000x (LoRA)

---

## Papers by Use Case

### Building a Unified Model
Must read: DiT, Flow Matching, MMDiT, SigLIP

### Long Video Understanding
Must read: RingAttention, 3D Causal VAE

### Efficient Deployment
Must read: LoRA, GQA, MoE

### Training Stability
Must read: QK-Norm, Flow Matching

### Frozen Backbone Approach
Must read: MetaQueries, LoRA

---

## Notes & Insights

### Personal Insights

*Add your own notes here as you read:*

**Paper 1: _________________**
- Key insight: ___________________
- Implementation idea: ___________________
- Questions: ___________________

**Paper 2: _________________**
- Key insight: ___________________
- Implementation idea: ___________________
- Questions: ___________________

### Related Papers to Explore

*Add papers you discover during reading:*

1. _________________ (arXiv:_________)
2. _________________ (arXiv:_________)
3. _________________ (arXiv:_________)

### Implementation Blockers

*Track what's blocking implementation:*

- [ ] _________________
- [ ] _________________
- [ ] _________________

---

## Timeline

### Reading Schedule

| Week | Papers | Implementation |
|------|--------|----------------|
| Week 1 | VQ-VAE, SigLIP | VQ-VAE from scratch |
| Week 2 | DiT, Flow Matching | DiT on MNIST |
| Week 3 | MMDiT, RingAttention | Flow Matching comparison |
| Week 4 | MoE, GQA, LoRA | MMDiT text-to-image |
| Week 5 | Rectified Flow, QK-Norm | Training optimization |
| Week 6 | 3D Causal VAE | Video tokenization |
| Week 7 | MetaQueries, Prefilled AR | Frozen backbone approach |
| Week 8 | Transfusion | Unified model prototype |

**Start Date:** ___________  
**Target Completion:** ___________

---

## Success Metrics

- [ ] Read all Tier 1 papers
- [ ] Implement 3 architectures from scratch
- [ ] Run experiments on at least 2 datasets
- [ ] Document findings in blog post / paper
- [ ] Contribute to open-source implementation

**Completion Date:** ___________

---

*Last Updated: February 2026*
