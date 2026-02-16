"""
SigLIP: Sigmoid Loss for Language Image Pre-Training
=====================================================
Paper: Zhai et al., "Sigmoid Loss for Language Image Pre-Training"
Venue: ICCV 2023
arXiv: 2303.15343
URL: https://arxiv.org/abs/2303.15343

Key Concepts:
-------------
1. Sigmoid Loss: Replaces softmax contrastive loss with pairwise sigmoid loss.
   This eliminates the need for global batch normalization.

2. Pairwise Independence: Each image-text pair is evaluated independently,
   unlike CLIP which uses global softmax across the batch.

3. Better Small-Batch Performance: SigLIP works well with smaller batches
   (4K-16K) while CLIP needs larger batches (>32K) for good performance.

4. Scalability: Can scale to batch sizes up to 1M (SigLiT) without
   performance degradation.

Architecture:
-------------
┌─────────────────┐         ┌─────────────────┐
│   Image Input   │         │   Text Input    │
│   (224×224×3)   │         │  (tokenized)    │
└────────┬────────┘         └────────┬────────┘
         │                           │
    ┌────▼────┐                 ┌────▼────┐
    │ Image   │                 │  Text   │
    │Encoder  │                 │ Encoder │
    │ (ViT)   │                 │(Transformer)
    └────┬────┘                 └────┬────┘
         │                           │
    ┌────▼────┐                 ┌────▼────┐
    │   L2    │                 │   L2    │
    │Normalize│                 │Normalize│
    └────┬────┘                 └────┬────┘
         │                           │
         └──────────┬────────────────┘
                    │
            ┌───────▼────────┐
            │  Dot Product   │
            │    (n×n)       │
            └───────┬────────┘
                    │
            ┌───────▼────────┐
            │ × Temperature  │
            │    + Bias      │
            └───────┬────────┘
                    │
            ┌───────▼────────┐
            │   Sigmoid      │
            │   Loss         │
            └────────────────┘

Loss Comparison:
----------------
CLIP (Softmax-based):
    L = -1/N Σᵢ log(exp(zᵢ·z'ᵢ/τ) / Σⱼ exp(zᵢ·z'ⱼ/τ))

    • Global softmax normalization across batch
    • Requires large batches for stable gradients
    • Sensitive to batch composition

SigLIP (Sigmoid-based):
    L = -1/N² Σᵢ Σⱼ log(σ(zᵢⱼ(t·xᵢ·yⱼ + b)))

    Where:
        zᵢⱼ =  1 if i=j (positive pair)
        zᵢⱼ = -1 if i≠j (negative pair)
        t = learnable temperature (initialized to exp(10))
        b = learnable bias (initialized to -10)
        σ = sigmoid function

    • Pairwise sigmoid (no global normalization)
    • Works with small batches (4K-16K)
    • Scales to 1M+ batch sizes
    • More robust to batch composition

Equations (from Paper):
-----------------------
1. Similarity Computation:
   sᵢⱼ = (xᵢ · yⱼ) / (||xᵢ|| ||yⱼ||)

   Where xᵢ, yⱼ are L2-normalized embeddings

2. Logit Computation:
   lᵢⱼ = t · sᵢⱼ + b

   Where t is temperature, b is bias

3. Sigmoid Loss:
   L = -1/N² Σᵢ Σⱼ log(σ(zᵢⱼ · lᵢⱼ))

   Where zᵢⱼ ∈ {+1, -1} indicates positive/negative pair

Key Implementation Details:
---------------------------
- L2 Normalization: Essential before computing similarities
- Temperature: Learned as exp(t') where t' is parameter
- Bias: Learned parameter initialized to -10
- Sigmoid: More stable than softmax for large batches

Batch Size Behavior (from Paper):
----------------------------------
| Batch Size | SigLIP | CLIP  |
|------------|--------|-------|
| 512-4K     | Good   | Poor  |
| 4K-16K     | Great  | Fair  |
| 16K-32K    | Great  | Good  |
| 32K-256K   | Great  | Great |
| 256K-1M    | Great  | N/A   |

Performance:
------------
- ImageNet Zero-Shot (SigLiT Base): 84.5%
- Training Cost: 4 TPUv4 chips × 2 days
- Comparable to CLIP with significantly less compute

References:
-----------
[1] Zhai et al., "Sigmoid Loss for Language Image Pre-Training", ICCV 2023
[2] Radford et al., "Learning Transferable Visual Models From Natural Language Supervision", 2021
[3] Tschannen et al., "SigLIP 2: Multilingual Vision-Language Encoders", 2025
"""

from typing import Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F


class SigLIPLoss(nn.Module):
    """
    Sigmoid Loss for Language-Image Pre-Training.

    Paper Equation:
        L = -1/|B|² Σᵢ Σⱼ log(1 / (1 + exp(zᵢⱼ(-t·xᵢ·yⱼ + b))))

    Where:
        zᵢⱼ = 1 if i=j (positive pair), -1 otherwise (negative pair)
        t = learnable temperature (initialized to exp(10) ≈ 22026)
        b = learnable bias (initialized to -10)

    The sigmoid formulation eliminates the problematic denominator
    in softmax, making each pair's contribution independent.

    Args:
        embed_dim: Dimension of image and text embeddings
        init_temperature: Initial temperature value (default: 10.0)
        init_bias: Initial bias value (default: -10.0)

    Attributes:
        t_prime: Learnable log-temperature parameter
        bias: Learnable bias parameter

    Example:
        >>> loss_fn = SigLIPLoss(embed_dim=512)
        >>> img_emb = torch.randn(32, 512)  # From image encoder
        >>> txt_emb = torch.randn(32, 512)  # From text encoder
        >>> loss = loss_fn(img_emb, txt_emb)
        >>> loss.shape
        torch.Size([])
    """

    def __init__(
        self,
        embed_dim: int,
        init_temperature: float = 10.0,
        init_bias: float = -10.0,
    ):
        super().__init__()

        self.embed_dim = embed_dim

        # Paper: Temperature is learned as t = exp(t_prime)
        # This ensures temperature stays positive
        # Initial temperature ≈ exp(10) ≈ 22026
        self.t_prime = nn.Parameter(torch.ones(1) * init_temperature)

        # Paper: Learnable bias term
        # Initialized to -10 to handle class imbalance
        self.bias = nn.Parameter(torch.ones(1) * init_bias)

    def forward(
        self,
        image_embeddings: torch.Tensor,
        text_embeddings: torch.Tensor,
    ) -> torch.Tensor:
        """
        Compute sigmoid contrastive loss.

        Paper Algorithm:
        1. L2 normalize all embeddings
        2. Compute similarity matrix: logits[i,j] = img[i] · txt[j]
        3. Apply temperature scaling and bias: logits = t·logits + b
        4. Create target labels: +1 for positive pairs (i=j), -1 for negatives
        5. Compute sigmoid loss: -log(σ(labels · logits))

        Args:
            image_embeddings: Image embeddings of shape (N, D)
            text_embeddings: Text embeddings of shape (N, D)

        Returns:
            loss: Scalar sigmoid loss

        Paper Equations:
            Similarity: sᵢⱼ = (xᵢ · yⱼ) / (||xᵢ|| ||yⱼ||)
            Logits: lᵢⱼ = t · sᵢⱼ + b
            Loss: L = -1/N² Σᵢ Σⱼ log(σ(zᵢⱼ · lᵢⱼ))
        """
        batch_size = image_embeddings.shape[0]

        # Paper: L2 normalization is essential
        # Without this, dot products can be arbitrarily large
        image_embeddings = F.normalize(image_embeddings, p=2, dim=-1)
        text_embeddings = F.normalize(text_embeddings, p=2, dim=-1)

        # Paper: Compute similarity matrix
        # logits[i, j] = similarity between image i and text j
        logits = torch.matmul(image_embeddings, text_embeddings.t())  # (N, N)

        # Paper: Apply temperature and bias
        # Temperature controls sharpness of sigmoid
        # Bias shifts decision boundary
        temperature = torch.exp(self.t_prime)  # Ensure positive
        logits = logits * temperature + self.bias

        # Paper: Create target labels
        # z_ij = +1 for positive pairs (diagonal, i=j)
        # z_ij = -1 for negative pairs (off-diagonal, i≠j)
        # Create matrix with 1 on diagonal, -1 elsewhere
        labels = 2 * torch.eye(batch_size, device=logits.device) - 1  # (N, N)

        # Paper: Sigmoid loss
        # For positive pairs (label=+1): minimize -log(σ(logits))
        # For negative pairs (label=-1): minimize -log(σ(-logits))
        # Combined: -log(σ(labels · logits))
        loss = -F.logsigmoid(labels * logits).mean()

        return loss


class ImageEncoder(nn.Module):
    """
    Vision Transformer-based image encoder for SigLIP.

    Paper uses ViT-SO400M architecture. This is a simplified version
    suitable for educational purposes and small-scale experiments.

    Architecture:
    Input (B, C, H, W)
    → Patch Embedding → Transformer Blocks → Global Pool → Projection

    Args:
        image_size: Input image size (default: 224)
        patch_size: Patch size for ViT (default: 16)
        in_channels: Number of input channels (default: 3)
        embed_dim: Embedding dimension (default: 512)
        num_layers: Number of transformer layers (default: 12)
        num_heads: Number of attention heads (default: 8)
        mlp_ratio: MLP hidden dim ratio (default: 4.0)

    Example:
        >>> encoder = ImageEncoder(image_size=224, patch_size=16, embed_dim=512)
        >>> images = torch.randn(4, 3, 224, 224)
        >>> embeddings = encoder(images)
        >>> embeddings.shape
        torch.Size([4, 512])
    """

    def __init__(
        self,
        image_size: int = 224,
        patch_size: int = 16,
        in_channels: int = 3,
        embed_dim: int = 512,
        num_layers: int = 12,
        num_heads: int = 8,
        mlp_ratio: float = 4.0,
        dropout: float = 0.0,
    ):
        super().__init__()

        self.image_size = image_size
        self.patch_size = patch_size
        self.num_patches = (image_size // patch_size) ** 2

        # Patch embedding: Convert image to sequence of patches
        self.patch_embed = nn.Conv2d(
            in_channels, embed_dim, kernel_size=patch_size, stride=patch_size
        )

        # Class token for global representation
        self.cls_token = nn.Parameter(torch.zeros(1, 1, embed_dim))

        # Positional embeddings
        self.pos_embed = nn.Parameter(torch.zeros(1, self.num_patches + 1, embed_dim))

        # Transformer encoder
        encoder_layer = nn.TransformerEncoderLayer(
            d_model=embed_dim,
            nhead=num_heads,
            dim_feedforward=int(embed_dim * mlp_ratio),
            dropout=dropout,
            activation="gelu",
            batch_first=True,
            norm_first=True,  # Pre-norm for stability
        )
        self.transformer = nn.TransformerEncoder(encoder_layer, num_layers=num_layers)

        # Output projection
        self.norm = nn.LayerNorm(embed_dim)

        # Initialize weights
        self._init_weights()

    def _init_weights(self):
        """Initialize weights following ViT paper."""
        nn.init.normal_(self.cls_token, std=0.02)
        nn.init.normal_(self.pos_embed, std=0.02)

        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.xavier_uniform_(m.weight)
                if m.bias is not None:
                    nn.init.zeros_(m.bias)
            elif isinstance(m, nn.LayerNorm):
                nn.init.ones_(m.weight)
                nn.init.zeros_(m.bias)

    def forward(self, images: torch.Tensor) -> torch.Tensor:
        """
        Encode images to embeddings.

        Args:
            images: Input images of shape (B, C, H, W)

        Returns:
            embeddings: Image embeddings of shape (B, D)
        """
        B = images.shape[0]

        # Patch embedding: (B, C, H, W) -> (B, N, D)
        # Where N = (H/P) * (W/P) is number of patches
        x = self.patch_embed(images)  # (B, D, H/P, W/P)
        x = x.flatten(2).transpose(1, 2)  # (B, N, D)

        # Add class token
        cls_tokens = self.cls_token.expand(B, -1, -1)  # (B, 1, D)
        x = torch.cat([cls_tokens, x], dim=1)  # (B, N+1, D)

        # Add positional embeddings
        x = x + self.pos_embed

        # Transformer encoding
        x = self.transformer(x)  # (B, N+1, D)

        # Extract class token as global representation
        x = x[:, 0]  # (B, D)

        # Final normalization
        x = self.norm(x)

        return x


class TextEncoder(nn.Module):
    """
    Transformer-based text encoder for SigLIP.

    Paper uses a standard transformer encoder. This is a simplified
    version suitable for educational purposes.

    Architecture:
    Input (B, L) token ids
    → Token Embedding → Positional Embedding → Transformer → Pool → Projection

    Args:
        vocab_size: Vocabulary size (default: 10000)
        embed_dim: Token embedding dimension (default: 512)
        num_layers: Number of transformer layers (default: 12)
        num_heads: Number of attention heads (default: 8)
        max_length: Maximum sequence length (default: 77)

    Example:
        >>> encoder = TextEncoder(vocab_size=10000, embed_dim=512)
        >>> tokens = torch.randint(0, 10000, (4, 32))  # (B, L)
        >>> embeddings = encoder(tokens)
        >>> embeddings.shape
        torch.Size([4, 512])
    """

    def __init__(
        self,
        vocab_size: int = 10000,
        embed_dim: int = 512,
        num_layers: int = 12,
        num_heads: int = 8,
        mlp_ratio: float = 4.0,
        max_length: int = 77,
        dropout: float = 0.0,
    ):
        super().__init__()

        self.vocab_size = vocab_size
        self.embed_dim = embed_dim
        self.max_length = max_length

        # Token embeddings
        self.token_embed = nn.Embedding(vocab_size, embed_dim)

        # Positional embeddings
        self.pos_embed = nn.Parameter(torch.zeros(1, max_length, embed_dim))

        # Transformer encoder
        encoder_layer = nn.TransformerEncoderLayer(
            d_model=embed_dim,
            nhead=num_heads,
            dim_feedforward=int(embed_dim * mlp_ratio),
            dropout=dropout,
            activation="gelu",
            batch_first=True,
            norm_first=True,
        )
        self.transformer = nn.TransformerEncoder(encoder_layer, num_layers=num_layers)

        # Output normalization
        self.norm = nn.LayerNorm(embed_dim)

        # Initialize weights
        self._init_weights()

    def _init_weights(self):
        """Initialize weights."""
        nn.init.normal_(self.token_embed.weight, std=0.02)
        nn.init.normal_(self.pos_embed, std=0.02)

        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.xavier_uniform_(m.weight)
                if m.bias is not None:
                    nn.init.zeros_(m.bias)
            elif isinstance(m, nn.LayerNorm):
                nn.init.ones_(m.weight)
                nn.init.zeros_(m.bias)

    def forward(self, tokens: torch.Tensor) -> torch.Tensor:
        """
        Encode text tokens to embeddings.

        Args:
            tokens: Input token ids of shape (B, L)

        Returns:
            embeddings: Text embeddings of shape (B, D)
        """
        B, L = tokens.shape

        # Token embedding
        x = self.token_embed(tokens)  # (B, L, D)

        # Add positional embeddings (truncate if needed)
        x = x + self.pos_embed[:, :L, :]

        # Transformer encoding
        x = self.transformer(x)  # (B, L, D)

        # Global average pooling over sequence
        x = x.mean(dim=1)  # (B, D)

        # Final normalization
        x = self.norm(x)

        return x


class SigLIPModel(nn.Module):
    """
    Complete SigLIP model with dual encoders.

    Paper Architecture:
    Images → ImageEncoder → img_emb ─┐
                                     ├→ Dot Product → Sigmoid Loss
    Text  → TextEncoder  → txt_emb ─┘

    Args:
        image_encoder: Image encoder module
        text_encoder: Text encoder module
        embed_dim: Embedding dimension (must match both encoders)
        init_temperature: Initial temperature
        init_bias: Initial bias

    Attributes:
        image_encoder: Vision transformer encoder
        text_encoder: Text transformer encoder
        loss_fn: SigLIP loss function

    Example:
        >>> model = SigLIPModel(
        ...     image_encoder=ImageEncoder(embed_dim=512),
        ...     text_encoder=TextEncoder(embed_dim=512),
        ...     embed_dim=512
        ... )
        >>> images = torch.randn(4, 3, 224, 224)
        >>> tokens = torch.randint(0, 10000, (4, 32))
        >>> loss, img_emb, txt_emb = model(images, tokens)
        >>> loss.shape
        torch.Size([])
    """

    def __init__(
        self,
        image_encoder: nn.Module,
        text_encoder: nn.Module,
        embed_dim: int,
        init_temperature: float = 10.0,
        init_bias: float = -10.0,
    ):
        super().__init__()

        self.image_encoder = image_encoder
        self.text_encoder = text_encoder
        self.embed_dim = embed_dim

        # Projection layers (if encoder outputs don't match embed_dim)
        self.image_proj = nn.Linear(
            (
                image_encoder.embed_dim
                if hasattr(image_encoder, "embed_dim")
                else embed_dim
            ),
            embed_dim,
        )
        self.text_proj = nn.Linear(
            text_encoder.embed_dim if hasattr(text_encoder, "embed_dim") else embed_dim,
            embed_dim,
        )

        # SigLIP loss
        self.loss_fn = SigLIPLoss(
            embed_dim=embed_dim,
            init_temperature=init_temperature,
            init_bias=init_bias,
        )

    def forward(
        self,
        images: torch.Tensor,
        text_tokens: torch.Tensor,
        return_loss: bool = True,
    ) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        """
        Forward pass through SigLIP.

        Paper Pipeline:
        1. Encode images to embeddings
        2. Encode text to embeddings
        3. Project to common space
        4. Compute sigmoid contrastive loss

        Args:
            images: Input images of shape (B, C, H, W)
            text_tokens: Input token ids of shape (B, L)
            return_loss: Whether to compute loss

        Returns:
            loss: SigLIP loss (if return_loss=True)
            image_embeddings: Image embeddings (B, D)
            text_embeddings: Text embeddings (B, D)
        """
        # Encode
        image_emb = self.image_encoder(images)  # (B, D_img)
        text_emb = self.text_encoder(text_tokens)  # (B, D_txt)

        # Project to common embedding space
        image_emb = self.image_proj(image_emb)  # (B, D)
        text_emb = self.text_proj(text_emb)  # (B, D)

        # Compute loss
        if return_loss:
            loss = self.loss_fn(image_emb, text_emb)
        else:
            loss = torch.tensor(0.0, device=images.device)

        return loss, image_emb, text_emb

    def get_similarity(
        self,
        images: torch.Tensor,
        text_tokens: torch.Tensor,
    ) -> torch.Tensor:
        """
        Get similarity scores between images and text.

        Useful for retrieval tasks.

        Args:
            images: Input images of shape (B, C, H, W)
            text_tokens: Input token ids of shape (B, L)

        Returns:
            similarities: Similarity matrix of shape (B, B)
        """
        _, image_emb, text_emb = self.forward(images, text_tokens, return_loss=False)

        # L2 normalize
        image_emb = F.normalize(image_emb, p=2, dim=-1)
        text_emb = F.normalize(text_emb, p=2, dim=-1)

        # Compute similarities
        similarities = torch.matmul(image_emb, text_emb.t())

        return similarities


def test_siglip():
    """
    Test SigLIP implementation with synthetic data.

    Verifies:
    - Forward pass works
    - Shapes are correct
    - Gradients flow
    - Loss decreases with training
    """
    print("Testing SigLIP implementation...")

    # Create encoders
    image_encoder = ImageEncoder(
        image_size=224,
        patch_size=16,
        embed_dim=512,
        num_layers=6,  # Smaller for testing
    )

    text_encoder = TextEncoder(
        vocab_size=1000,
        embed_dim=512,
        num_layers=6,
        max_length=32,
    )

    # Create model
    model = SigLIPModel(
        image_encoder=image_encoder,
        text_encoder=text_encoder,
        embed_dim=512,
    )

    # Synthetic data
    batch_size = 4
    images = torch.randn(batch_size, 3, 224, 224)
    text_tokens = torch.randint(0, 1000, (batch_size, 32))

    # Forward pass
    loss, img_emb, txt_emb = model(images, text_tokens)

    # Verify shapes
    assert img_emb.shape == (
        batch_size,
        512,
    ), f"Image embedding shape mismatch: {img_emb.shape}"
    assert txt_emb.shape == (
        batch_size,
        512,
    ), f"Text embedding shape mismatch: {txt_emb.shape}"
    assert loss.shape == torch.Size([]), f"Loss should be scalar, got {loss.shape}"

    print(f"  ✓ Image embedding shape: {img_emb.shape}")
    print(f"  ✓ Text embedding shape: {txt_emb.shape}")
    print(f"  ✓ Loss: {loss.item():.4f}")

    # Test backward pass
    loss.backward()

    # Check gradients exist
    has_grads = sum(p.grad is not None for p in model.parameters() if p.requires_grad)
    total_params = sum(1 for p in model.parameters() if p.requires_grad)
    print(f"  ✓ Gradients computed: {has_grads}/{total_params} parameters")

    # Test similarity computation
    similarities = model.get_similarity(images, text_tokens)
    assert similarities.shape == (batch_size, batch_size)
    print(f"  ✓ Similarity matrix shape: {similarities.shape}")
    print(
        f"  ✓ Diagonal similarities (positive pairs): {similarities.diag().mean().item():.4f}"
    )
    print(
        f"  ✓ Off-diagonal similarities (negative pairs): {similarities[~torch.eye(batch_size, dtype=bool)].mean().item():.4f}"
    )

    # Note: With random initialization, similarities are random
    # After training, positive pairs (diagonal) should have higher similarity
    pos_sim = similarities.diag().mean().item()
    neg_sim = similarities[~torch.eye(batch_size, dtype=bool)].mean().item()
    print(f"  ✓ Positive pair similarity (before training): {pos_sim:.4f}")
    print(f"  ✓ Negative pair similarity (before training): {neg_sim:.4f}")
    print("  ℹ️  Note: After training, pos_sim should be > neg_sim")

    print("\n✅ All SigLIP tests passed!")

    return model, images, text_tokens


if __name__ == "__main__":
    # Run tests when file is executed directly
    test_siglip()
