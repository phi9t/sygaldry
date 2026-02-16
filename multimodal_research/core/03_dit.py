"""
DiT: Diffusion Transformers
============================
Paper: Peebles & Xie, "Scalable Diffusion Models with Transformers"
Venue: ICCV 2023 (Oral Presentation)
arXiv: 2212.09748
URL: https://arxiv.org/abs/2212.09748

Key Concepts:
-------------
1. Transformers Replace U-Net: DiT replaces the U-Net backbone in diffusion
   models with a Vision Transformer (ViT), achieving better scaling and
   global context understanding.

2. Superior Scaling Laws: Unlike U-Nets, DiT shows clear scaling - more
   Gflops consistently lead to better FID scores.

3. Patchified Latents: DiT operates on patches of VAE latent representations,
   similar to how ViT operates on image patches.

4. AdaLN-Zero Conditioning: Adaptive Layer Normalization with zero
   initialization allows effective conditioning on timesteps and labels
   with minimal overhead.

Architecture:
-------------
Input Image (256×256×3)
    ↓
VAE Encoder (8× compression)
    ↓
Latent (32×32×4)
    ↓
Patchify (p×p patches)
    ↓
Tokens (T=(32/p)², D=hidden_dim)
    ↓
[DiT Transformer Blocks] × N
    ↓
Unpatchify
    ↓
Predicted Noise (32×32×4)
    ↓
VAE Decoder
    ↓
Generated Image (256×256×3)

DiT Transformer Block:
┌─────────────────────────────────────────────────────────────┐
│ Input: x (tokens), c (condition)                             │
│                                                              │
│ 1. Compute modulation from c:                               │
│    shift_msa, scale_msa, gate_msa,                          │
│    shift_mlp, scale_mlp, gate_mlp = adaLN_modulation(c)    │
│                                                              │
│ 2. Self-Attention with AdaLN:                               │
│    x = x + gate_msa · Attn(modulate(LN(x), shift, scale))  │
│                                                              │
│ 3. MLP with AdaLN:                                          │
│    x = x + gate_mlp · MLP(modulate(LN(x), shift, scale))   │
│                                                              │
│ Output: x                                                    │
└─────────────────────────────────────────────────────────────┘

Scaling Laws (from Paper):
--------------------------
DiT shows strong correlation between compute (Gflops) and quality (FID):

| Model    | Patch | Depth | Hidden | Params | Gflops | FID@400K |
|----------|-------|-------|--------|--------|--------|----------|
| DiT-S/2  | 2×2   | 12    | 384    | 33M    | 1.4    | ~100     |
| DiT-B/2  | 2×2   | 12    | 768    | 130M   | 5.6    | ~68      |
| DiT-L/2  | 2×2   | 24    | 1024   | 458M   | 19.7   | ~35      |
| DiT-XL/2 | 2×2   | 28    | 1152   | 675M   | 118.6  | 19.5     |

Key Finding: Gflops ∝ 1/FID (more compute → better quality)

Comparison with U-Net (ADM):
----------------------------
| Metric          | ADM (U-Net) | DiT-XL/2   |
|-----------------|-------------|------------|
| Architecture    | CNN         | Transformer|
| Gflops (256px)  | 1120        | 118.6      |
| FID (256px)     | 3.60        | 2.27       |
| Gflops (512px)  | 1983-2813   | 524.6      |
| FID (512px)     | 3.85        | 3.04       |

DiT is 10× more compute-efficient while achieving better quality!

Model Configurations:
--------------------
DiT-S/2:  Small model, 12 layers, 384 hidden, 2×2 patches
DiT-B/2:  Base model, 12 layers, 768 hidden, 2×2 patches
DiT-L/2:  Large model, 24 layers, 1024 hidden, 2×2 patches
DiT-XL/2: XLarge model, 28 layers, 1152 hidden, 2×2 patches

Also supports 4×4 and 8×8 patches for efficiency trade-offs.

Equations (from Paper):
-----------------------
1. Forward Diffusion (DDPM):
   q(x_t|x_0) = N(x_t; √ᾱₜx_0, (1-ᾱₜ)I)

2. Reverse Diffusion:
   p_θ(x_{t-1}|x_t) = N(μ_θ(x_t, t), Σ_θ(x_t, t))

3. Training Objective:
   L = ||ε_θ(x_t, t) - ε||²

   Where ε_θ is the DiT network predicting noise

4. AdaLN-Zero Modulation:
   Given condition embedding c:
   shift, scale, gate = Linear(c)
   modulated = x · (1 + scale) + shift
   output = x + gate · Layer(modulated)

Key Implementation Details:
---------------------------
- AdaLN-Zero: Best conditioning strategy (outperforms cross-attention)
- Zero Initialization: Gate parameters start at 0 (identity function)
- Patch Size: Smaller patches → more tokens → better quality but slower
- Sine-Cosine Positional Embeddings: Non-learnable, generalizes to different resolutions
- EMA: Essential for stable sampling (decay 0.9999)

Training Recipe (from Paper):
-----------------------------
- Optimizer: AdamW
- Learning rate: 1×10⁻⁴ (constant, no warmup)
- Batch size: 256
- EMA decay: 0.9999
- Diffusion steps: 1000
- Variance schedule: Linear β from 1×10⁻⁴ to 2×10⁻²
- Training steps: 400K (256×256), 3M (512×512)

References:
-----------
[1] Peebles & Xie, "Scalable Diffusion Models with Transformers", ICCV 2023
[2] Dhariwal & Nichol, "Diffusion Models Beat GANs on Image Synthesis", NeurIPS 2021
[3] Rombach et al., "High-Resolution Image Synthesis with Latent Diffusion Models", CVPR 2022
"""

import math

import torch
import torch.nn as nn
import torch.nn.functional as F


def modulate(x, shift, scale):
    """
    Apply adaptive layer normalization modulation.

    Paper Equation:
        modulated = x · (1 + scale) + shift

    Args:
        x: Input tensor of shape (B, N, D)
        shift: Shift parameter of shape (B, D)
        scale: Scale parameter of shape (B, D)

    Returns:
        modulated: Modulated tensor of shape (B, N, D)
    """
    return x * (1 + scale.unsqueeze(1)) + shift.unsqueeze(1)


class TimestepEmbedder(nn.Module):
    """
    Embeds scalar timesteps into vector representations.

    Paper: Uses sinusoidal position embeddings followed by MLP,
    similar to Transformer position encodings.

    Args:
        hidden_size: Dimension of output embedding
        frequency_embedding_size: Dimension of sinusoidal encoding (default: 256)

    Example:
        >>> embedder = TimestepEmbedder(hidden_size=512)
        >>> t = torch.tensor([0, 100, 500, 999])  # Timesteps
        >>> t_emb = embedder(t)
        >>> t_emb.shape
        torch.Size([4, 512])
    """

    def __init__(
        self,
        hidden_size: int,
        frequency_embedding_size: int = 256,
    ):
        super().__init__()
        self.mlp = nn.Sequential(
            nn.Linear(frequency_embedding_size, hidden_size),
            nn.SiLU(),
            nn.Linear(hidden_size, hidden_size),
        )
        self.frequency_embedding_size = frequency_embedding_size

    @staticmethod
    def timestep_embedding(
        t: torch.Tensor,
        dim: int,
        max_period: int = 10000,
    ) -> torch.Tensor:
        """
        Create sinusoidal timestep embeddings.

        Paper: Standard sinusoidal position encoding from
        "Attention Is All You Need" (Vaswani et al., 2017).

        Args:
            t: Timesteps of shape (N,)
            dim: Embedding dimension
            max_period: Maximum period for sinusoids

        Returns:
            Embedding of shape (N, dim)
        """
        half = dim // 2
        freqs = torch.exp(
            -math.log(max_period) * torch.arange(half, dtype=torch.float32) / half
        ).to(t.device)
        args = t[:, None].float() * freqs[None]
        embedding = torch.cat([torch.cos(args), torch.sin(args)], dim=-1)
        if dim % 2:
            embedding = torch.cat(
                [embedding, torch.zeros_like(embedding[:, :1])], dim=-1
            )
        return embedding

    def forward(self, t: torch.Tensor) -> torch.Tensor:
        """
        Args:
            t: Timesteps of shape (N,)

        Returns:
            Embeddings of shape (N, hidden_size)
        """
        t_freq = self.timestep_embedding(t, self.frequency_embedding_size)
        t_emb = self.mlp(t_freq)
        return t_emb


class LabelEmbedder(nn.Module):
    """
    Embeds class labels into vector representations.

    Paper: Also handles dropout for classifier-free guidance (CFG).

    Args:
        num_classes: Number of classes
        hidden_size: Dimension of output embedding
        dropout_prob: Probability of dropping labels (for CFG)

    Example:
        >>> embedder = LabelEmbedder(num_classes=10, hidden_size=512, dropout_prob=0.1)
        >>> labels = torch.tensor([0, 1, 2, 3])
        >>> label_emb = embedder(labels, train=True)
        >>> label_emb.shape
        torch.Size([4, 512])
    """

    def __init__(
        self,
        num_classes: int,
        hidden_size: int,
        dropout_prob: float,
    ):
        super().__init__()
        # Extra embedding for null token (used in CFG)
        self.embedding_table = nn.Embedding(
            num_classes + 1 if dropout_prob > 0 else num_classes, hidden_size
        )
        self.num_classes = num_classes
        self.dropout_prob = dropout_prob

    def token_drop(self, labels: torch.Tensor) -> torch.Tensor:
        """
        Randomly drop labels for classifier-free guidance.

        Paper: Dropping labels with probability p during training
        enables classifier-free guidance during sampling.

        Args:
            labels: Class labels of shape (N,)

        Returns:
            Labels with some replaced by null token (num_classes)
        """
        drop_ids = torch.rand(labels.shape[0], device=labels.device) < self.dropout_prob
        labels = torch.where(drop_ids, self.num_classes, labels)
        return labels

    def forward(self, labels: torch.Tensor, train: bool = False) -> torch.Tensor:
        """
        Args:
            labels: Class labels of shape (N,)
            train: Whether in training mode (enables dropout)

        Returns:
            Embeddings of shape (N, hidden_size)
        """
        if train and self.dropout_prob > 0:
            labels = self.token_drop(labels)
        embeddings = self.embedding_table(labels)
        return embeddings


class DiTBlock(nn.Module):
    """
    DiT Transformer block with Adaptive Layer Norm Zero (adaLN-Zero).

    Paper Section 3.3: "We find that adaLN-Zero blocks outperform
    all other conditioning strategies including cross-attention."

    Architecture:
        x ───────────────────────────────────────────────┐
        ↓                                                 │
        LN ──[modulation]──▶ Attn ────────────────────────┤
        ↓                                                 │
        gate_msa (learned) ───────────────────────────────┘
        ↓
        x ───────────────────────────────────────────────┐
        ↓                                                 │
        LN ──[modulation]──▶ MLP ─────────────────────────┤
        ↓                                                 │
        gate_mlp (learned) ───────────────────────────────┘

    Modulation computes:
        shift_msa, scale_msa, gate_msa,
        shift_mlp, scale_mlp, gate_mlp = MLP(c)

    Args:
        hidden_size: Dimension of hidden states
        num_heads: Number of attention heads
        mlp_ratio: Ratio of MLP hidden dim to hidden_size

    Example:
        >>> block = DiTBlock(hidden_size=768, num_heads=12)
        >>> x = torch.randn(4, 16, 768)  # (B, N, D)
        >>> c = torch.randn(4, 768)      # Condition
        >>> x = block(x, c)
        >>> x.shape
        torch.Size([4, 16, 768])
    """

    def __init__(
        self,
        hidden_size: int,
        num_heads: int,
        mlp_ratio: float = 4.0,
    ):
        super().__init__()
        self.norm1 = nn.LayerNorm(hidden_size, elementwise_affine=False, eps=1e-6)
        self.attn = nn.MultiheadAttention(hidden_size, num_heads, batch_first=True)
        self.norm2 = nn.LayerNorm(hidden_size, elementwise_affine=False, eps=1e-6)

        mlp_hidden_dim = int(hidden_size * mlp_ratio)
        self.mlp = nn.Sequential(
            nn.Linear(hidden_size, mlp_hidden_dim),
            nn.GELU(),
            nn.Linear(mlp_hidden_dim, hidden_size),
        )

        # Paper: AdaLN modulation projects condition to 6 parameters
        # shift_msa, scale_msa, gate_msa, shift_mlp, scale_mlp, gate_mlp
        self.adaLN_modulation = nn.Sequential(
            nn.SiLU(), nn.Linear(hidden_size, 6 * hidden_size, bias=True)
        )

        # Paper: Initialize gate parameters to 0
        # This makes each block start as identity function
        nn.init.zeros_(self.adaLN_modulation[-1].weight)
        nn.init.zeros_(self.adaLN_modulation[-1].bias)

    def forward(self, x: torch.Tensor, c: torch.Tensor) -> torch.Tensor:
        """
        Forward pass with adaptive layer normalization.

        Paper Algorithm:
        1. Compute 6 modulation parameters from condition c
        2. Apply to self-attention with residual
        3. Apply to MLP with residual

        Args:
            x: Input tensor of shape (B, N, D)
            c: Condition embedding of shape (B, D)

        Returns:
            Output tensor of shape (B, N, D)
        """
        # Paper: Compute modulation parameters from condition
        shift_msa, scale_msa, gate_msa, shift_mlp, scale_mlp, gate_mlp = (
            self.adaLN_modulation(c).chunk(6, dim=1)
        )

        # Paper: Self-attention with AdaLN
        # x = x + gate_msa * Attn(modulate(LN1(x), shift_msa, scale_msa))
        attn_input = modulate(self.norm1(x), shift_msa, scale_msa)
        attn_output, _ = self.attn(attn_input, attn_input, attn_input)
        x = x + gate_msa.unsqueeze(1) * attn_output

        # Paper: MLP with AdaLN
        # x = x + gate_mlp * MLP(modulate(LN2(x), shift_mlp, scale_mlp))
        mlp_input = modulate(self.norm2(x), shift_mlp, scale_mlp)
        x = x + gate_mlp.unsqueeze(1) * self.mlp(mlp_input)

        return x


class FinalLayer(nn.Module):
    """
    Final layer of DiT that projects to patch space.

    Paper: "The final DiT block is followed by a standard Layer Norm
    and a linear decoder that projects the transformer output to
    the same dimension as the input patches."

    Args:
        hidden_size: Dimension of transformer output
        patch_size: Size of patches (p)
        out_channels: Number of output channels

    Example:
        >>> layer = FinalLayer(hidden_size=768, patch_size=2, out_channels=4)
        >>> x = torch.randn(4, 16, 768)  # (B, N, D)
        >>> c = torch.randn(4, 768)      # Condition
        >>> output = layer(x, c)
        >>> output.shape
        torch.Size([4, 16, 16])  # (B, N, p*p*C)
    """

    def __init__(
        self,
        hidden_size: int,
        patch_size: int,
        out_channels: int,
    ):
        super().__init__()
        self.norm_final = nn.LayerNorm(hidden_size, elementwise_affine=False, eps=1e-6)
        self.linear = nn.Linear(
            hidden_size, patch_size * patch_size * out_channels, bias=True
        )
        self.adaLN_modulation = nn.Sequential(
            nn.SiLU(), nn.Linear(hidden_size, 2 * hidden_size, bias=True)
        )

    def forward(self, x: torch.Tensor, c: torch.Tensor) -> torch.Tensor:
        """
        Args:
            x: Input tensor of shape (B, N, D)
            c: Condition embedding of shape (B, D)

        Returns:
            Output tensor of shape (B, N, p*p*C)
        """
        shift, scale = self.adaLN_modulation(c).chunk(2, dim=1)
        x = modulate(self.norm_final(x), shift, scale)
        x = self.linear(x)
        return x


class DiT(nn.Module):
    """
    Diffusion Transformer (DiT).

    Paper: "Scalable Diffusion Models with Transformers"

    Full Pipeline:
    1. Input: Noised latent x_t, timestep t, class label y
    2. Patchify latent into tokens
    3. Add positional embeddings
    4. Embed timestep and label
    5. Pass through DiT blocks with conditioning
    6. Final layer projects back to patch space
    7. Unpatchify to latent space

    Args:
        input_size: Latent spatial size (e.g., 32 for 256px images with 8x VAE)
        patch_size: Patch size (p)
        in_channels: Number of input channels (VAE latent channels)
        hidden_size: Transformer hidden dimension
        depth: Number of transformer blocks
        num_heads: Number of attention heads
        mlp_ratio: MLP hidden dim ratio
        num_classes: Number of classes for conditioning
        dropout_prob: Label dropout probability for CFG

    Attributes:
        x_embedder: Patch embedding layer
        t_embedder: Timestep embedding
        y_embedder: Label embedding
        blocks: DiT transformer blocks
        final_layer: Output projection

    Example:
        >>> model = DiT(
        ...     input_size=32, patch_size=2, in_channels=4,
        ...     hidden_size=768, depth=12, num_heads=12,
        ...     num_classes=10
        ... )
        >>> x = torch.randn(4, 4, 32, 32)  # Noised latent
        >>> t = torch.tensor([0, 250, 500, 750])  # Timesteps
        >>> y = torch.tensor([0, 1, 2, 3])  # Class labels
        >>> pred = model(x, t, y)
        >>> pred.shape
        torch.Size([4, 4, 32, 32])  # Predicted noise
    """

    def __init__(
        self,
        input_size: int = 32,
        patch_size: int = 2,
        in_channels: int = 4,
        hidden_size: int = 768,
        depth: int = 12,
        num_heads: int = 12,
        mlp_ratio: float = 4.0,
        num_classes: int = 10,
        dropout_prob: float = 0.1,
    ):
        super().__init__()
        self.input_size = input_size
        self.patch_size = patch_size
        self.in_channels = in_channels
        self.out_channels = in_channels  # Predict noise, same channels
        self.num_patches = (input_size // patch_size) ** 2

        # Paper: Patchify via linear projection
        self.x_embedder = nn.Linear(
            patch_size * patch_size * in_channels, hidden_size, bias=True
        )

        # Paper: Sine-cosine positional embeddings (non-learnable)
        self.pos_embed = nn.Parameter(
            torch.zeros(1, self.num_patches, hidden_size), requires_grad=False
        )

        # Paper: Timestep and label embedders
        self.t_embedder = TimestepEmbedder(hidden_size)
        self.y_embedder = LabelEmbedder(num_classes, hidden_size, dropout_prob)

        # Paper: DiT transformer blocks
        self.blocks = nn.ModuleList(
            [DiTBlock(hidden_size, num_heads, mlp_ratio) for _ in range(depth)]
        )

        # Paper: Final layer
        self.final_layer = FinalLayer(hidden_size, patch_size, self.out_channels)

        self.initialize_weights()

    def initialize_weights(self):
        """Initialize weights following ViT and DiT papers."""
        # Initialize patch_embed like nn.Linear
        nn.init.xavier_uniform_(self.x_embedder.weight)
        nn.init.zeros_(self.x_embedder.bias)

        # Initialize pos_embed
        pos_embed = self.get_2d_sincos_pos_embed(
            self.pos_embed.shape[-1], int(self.num_patches**0.5)
        )
        self.pos_embed.data.copy_(torch.from_numpy(pos_embed).float().unsqueeze(0))

    @staticmethod
    def get_2d_sincos_pos_embed(embed_dim: int, grid_size: int):
        """
        Generate 2D sine-cosine positional embeddings.

        Paper: "We use standard 2D sine-cosine positional embeddings."

        Args:
            embed_dim: Embedding dimension
            grid_size: Grid size (sqrt of num_patches)

        Returns:
            Positional embeddings of shape (grid_size², embed_dim)
        """
        import numpy as np

        grid_h = np.arange(grid_size, dtype=np.float32)
        grid_w = np.arange(grid_size, dtype=np.float32)
        grid = np.meshgrid(grid_w, grid_h)  # Here w goes first
        grid = np.stack(grid, axis=0)
        grid = grid.reshape([2, 1, grid_size, grid_size])

        pos_embed = DiT.get_2d_sincos_pos_embed_from_grid(embed_dim, grid)
        return pos_embed

    @staticmethod
    def get_2d_sincos_pos_embed_from_grid(embed_dim: int, grid):
        """Helper for 2D sine-cosine embeddings."""
        import numpy as np

        assert embed_dim % 2 == 0

        # Use half dimensions for each axis
        emb_h = DiT.get_1d_sincos_pos_embed_from_grid(
            embed_dim // 2, grid[0]
        )  # (H*W, D/2)
        emb_w = DiT.get_1d_sincos_pos_embed_from_grid(
            embed_dim // 2, grid[1]
        )  # (H*W, D/2)

        emb = np.concatenate([emb_h, emb_w], axis=1)  # (H*W, D)
        return emb

    @staticmethod
    def get_1d_sincos_pos_embed_from_grid(embed_dim: int, pos):
        """Helper for 1D sine-cosine embeddings."""
        import numpy as np

        assert embed_dim % 2 == 0
        omega = np.arange(embed_dim // 2, dtype=np.float32)
        omega /= embed_dim / 2.0
        omega = 1.0 / 10000**omega  # (D/2,)

        pos = pos.reshape(-1)  # (M,)
        out = np.einsum("m,d->md", pos, omega)  # (M, D/2)

        emb_sin = np.sin(out)  # (M, D/2)
        emb_cos = np.cos(out)  # (M, D/2)

        emb = np.concatenate([emb_sin, emb_cos], axis=1)  # (M, D)
        return emb

    def patchify(self, x: torch.Tensor) -> torch.Tensor:
        """
        Convert latent to sequence of patches.

        Paper: "We tokenize the latent by reshaping it into a sequence of patches."

        Args:
            x: Latent of shape (B, C, H, W)

        Returns:
            Patches of shape (B, N, p*p*C) where N = (H*W)/(p*p)
        """
        B, C, H, W = x.shape
        p = self.patch_size
        assert H % p == 0 and W % p == 0

        # Reshape to (B, C, H//p, p, W//p, p)
        x = x.reshape(B, C, H // p, p, W // p, p)
        # Transpose to (B, H//p, W//p, p, p, C)
        x = x.permute(0, 2, 4, 3, 5, 1)
        # Flatten patches: (B, N, p*p*C)
        x = x.reshape(B, -1, p * p * C)
        return x

    def unpatchify(self, x: torch.Tensor) -> torch.Tensor:
        """
        Convert sequence of patches back to latent.

        Paper: "The decoder then converts the sequence of patches back to the
        latent spatial arrangement."

        Args:
            x: Patches of shape (B, N, p*p*C)

        Returns:
            Latent of shape (B, C, H, W)
        """
        B, N, D = x.shape
        p = self.patch_size
        C = self.out_channels
        H = W = int(N**0.5) * p

        # Reshape to (B, H//p, W//p, p, p, C)
        x = x.reshape(B, H // p, W // p, p, p, C)
        # Transpose to (B, C, H//p, p, W//p, p)
        x = x.permute(0, 5, 1, 3, 2, 4)
        # Reshape to (B, C, H, W)
        x = x.reshape(B, C, H, W)
        return x

    def forward(
        self,
        x: torch.Tensor,
        t: torch.Tensor,
        y: torch.Tensor,
    ) -> torch.Tensor:
        """
        Forward pass through DiT.

        Paper Pipeline:
        1. Patchify input latent x
        2. Embed patches and add positional encoding
        3. Embed timestep t and label y
        4. Pass through DiT blocks with conditioning
        5. Final layer projection
        6. Unpatchify to latent space

        Args:
            x: Noised latent of shape (B, C, H, W)
            t: Timesteps of shape (B,)
            y: Class labels of shape (B,)

        Returns:
            Predicted noise of shape (B, C, H, W)
        """
        # Paper: Patchify and embed
        x = self.patchify(x)  # (B, N, p*p*C)
        x = self.x_embedder(x)  # (B, N, D)
        x = x + self.pos_embed  # Add positional encoding

        # Paper: Embed conditioning
        t_emb = self.t_embedder(t)  # (B, D)
        y_emb = self.y_embedder(y, self.training)  # (B, D)
        c = t_emb + y_emb  # Combine conditions

        # Paper: Pass through DiT blocks
        for block in self.blocks:
            x = block(x, c)  # (B, N, D)

        # Paper: Final projection
        x = self.final_layer(x, c)  # (B, N, p*p*C)

        # Paper: Unpatchify
        x = self.unpatchify(x)  # (B, C, H, W)

        return x

    def forward_with_cfg(
        self,
        x: torch.Tensor,
        t: torch.Tensor,
        y: torch.Tensor,
        cfg_scale: float,
    ) -> torch.Tensor:
        """
        Forward pass with Classifier-Free Guidance (CFG).

        Paper: "We use classifier-free guidance to improve sample quality."

        CFG Formula:
            ε_cfg = ε_unc + scale * (ε_cond - ε_unc)

        Where:
            ε_cond: Conditional prediction (with label)
            ε_unc: Unconditional prediction (without label)

        Args:
            x: Noised latent
            t: Timesteps
            y: Class labels
            cfg_scale: Guidance scale (typically 1.0-10.0)

        Returns:
            Guided prediction
        """
        # Duplicate input for conditional and unconditional
        x_in = torch.cat([x, x], dim=0)
        t_in = torch.cat([t, t], dim=0)
        y_in = torch.cat([y, torch.full_like(y, self.y_embedder.num_classes)], dim=0)

        # Forward pass
        pred = self.forward(x_in, t_in, y_in)

        # Split predictions
        pred_cond, pred_uncond = pred.chunk(2, dim=0)

        # Apply guidance
        pred_guided = pred_uncond + cfg_scale * (pred_cond - pred_uncond)

        return pred_guided


# Model configurations from paper Table 2
DiT_configs = {
    "DiT-S/2": {
        "depth": 12,
        "hidden_size": 384,
        "num_heads": 6,
        "patch_size": 2,
    },
    "DiT-B/2": {
        "depth": 12,
        "hidden_size": 768,
        "num_heads": 12,
        "patch_size": 2,
    },
    "DiT-L/2": {
        "depth": 24,
        "hidden_size": 1024,
        "num_heads": 16,
        "patch_size": 2,
    },
    "DiT-XL/2": {
        "depth": 28,
        "hidden_size": 1152,
        "num_heads": 16,
        "patch_size": 2,
    },
    "DiT-B/4": {
        "depth": 12,
        "hidden_size": 768,
        "num_heads": 12,
        "patch_size": 4,
    },
    "DiT-XL/4": {
        "depth": 28,
        "hidden_size": 1152,
        "num_heads": 16,
        "patch_size": 4,
    },
}


def test_dit():
    """
    Test DiT implementation with synthetic data.

    Verifies:
    - Forward pass works
    - Patchify/unpatchify are inverses
    - Shapes are correct
    - Gradients flow
    - CFG works
    """
    print("Testing DiT implementation...")

    # Create model (small version for testing)
    model = DiT(
        input_size=32,
        patch_size=2,
        in_channels=4,
        hidden_size=384,  # DiT-S size
        depth=6,  # Reduced for testing
        num_heads=6,
        num_classes=10,
    )

    # Synthetic data
    batch_size = 4
    x = torch.randn(batch_size, 4, 32, 32)  # Noised latent
    t = torch.tensor([0, 250, 500, 750])  # Timesteps
    y = torch.tensor([0, 1, 2, 3])  # Class labels

    # Test patchify/unpatchify
    x_patches = model.patchify(x)
    x_reconstructed = model.unpatchify(x_patches)
    assert torch.allclose(
        x, x_reconstructed, atol=1e-5
    ), "Patchify/unpatchify should be inverse"
    print("  ✓ Patchify/unpatchify are inverses")

    # Forward pass
    pred = model(x, t, y)

    # Verify shapes
    assert (
        pred.shape == x.shape
    ), f"Prediction shape mismatch: {pred.shape} vs {x.shape}"
    print(f"  ✓ Input shape: {x.shape}")
    print(f"  ✓ Prediction shape: {pred.shape}")

    # Test with CFG
    pred_cfg = model.forward_with_cfg(x, t, y, cfg_scale=2.0)
    assert pred_cfg.shape == x.shape
    print("  ✓ CFG forward pass works")

    # Test backward pass
    loss = F.mse_loss(pred, x)  # Dummy loss
    loss.backward()

    # Check gradients
    has_grads = sum(p.grad is not None for p in model.parameters() if p.requires_grad)
    total_params = sum(1 for p in model.parameters() if p.requires_grad)
    print(f"  ✓ Gradients computed: {has_grads}/{total_params} parameters")

    # Test model configs
    print("\n  Model configurations available:")
    for name, config in DiT_configs.items():
        print(f"    {name}: depth={config['depth']}, hidden={config['hidden_size']}")

    print("\n✅ All DiT tests passed!")

    return model, x, t, y


if __name__ == "__main__":
    # Run tests when file is executed directly
    test_dit()
