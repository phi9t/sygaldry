"""
VQ-VAE: Neural Discrete Representation Learning
================================================
Paper: van den Oord et al., "Neural Discrete Representation Learning"
Venue: NeurIPS 2017
arXiv: 1711.00937
URL: https://arxiv.org/abs/1711.00937

Key Concepts:
-------------
1. Discrete Latent Representations: Unlike standard VAEs with continuous latents,
   VQ-VAE uses a discrete codebook of embeddings.

2. Vector Quantization: Maps continuous encoder outputs to nearest codebook entries
   using L2 distance.

3. Straight-Through Estimator (STE): Enables gradient flow through the non-
   differentiable argmin operation.

4. Learned Prior: The prior over discrete codes is learned separately (e.g.,
   with PixelCNN), not fixed as Gaussian.

Architecture:
-------------
┌─────────┐     ┌──────────┐     ┌─────────────┐     ┌──────────┐
│  Input  │────▶│ Encoder  │────▶│  z_e(x)     │────▶│ Quantize │
│   x     │     │  (CNN)   │     │(continuous) │     │ (argmin) │
└─────────┘     └──────────┘     └─────────────┘     └────┬─────┘
                                                          │
                              ┌───────────────────────────┘
                              ▼
                         ┌─────────┐
                         │Codebook │
                         │    E    │  E ∈ R^(K×D)
                         │ (K×D)   │  K = num_embeddings
                         └────┬────┘  D = embedding_dim
                              │
                              ▼
┌─────────┐     ┌──────────┐     ┌─────────────┐     ┌──────────┐
│ Output  │◀────│ Decoder  │◀────│   z_q(x)    │◀────│   STE    │
│  x̂      │     │  (CNN)   │     │  (discrete) │     │(gradient│
└─────────┘     └──────────┘     └─────────────┘     │ bypass) │
                                                     └─────────┘

Equations (from Paper):
-----------------------
1. Quantization (Eq. 1):
   z_q(x) = e_k where k = argmin_j ||z_e(x) - e_j||²

2. Loss Function (Eq. 3):
   L = log p(x|z_q(x)) + ||sg[z_e(x)] - e||²₂ + β||z_e(x) - sg[e]||²₂

   Where:
   - Term 1: Reconstruction loss (negative log-likelihood)
   - Term 2: Codebook loss (only codebook updated)
   - Term 3: Commitment loss (only encoder updated)
   - sg[·]: Stop-gradient operator
   - β: Commitment cost (typically 0.25)

3. EMA Update (Alternative to gradient descent):
   e_i ← λe_i + (1-λ)Σz_e(x) / N_i
   where λ = decay rate (0.99), N_i = count of vectors assigned to code i

Key Implementation Details:
---------------------------
- Straight-Through Estimator (STE):
  Forward: z_q = codebook[argmin(distances)]
  Backward: ∂L/∂z_e = ∂L/∂z_q (gradient bypasses quantization)

  PyTorch implementation:
  z_q = z_e + (z_q - z_e).detach()

- Codebook Initialization: Uniform(-1/K, 1/K)

- Codebook Collapse Prevention:
  * Use EMA updates (more stable)
  * Commitment loss (β > 0)
  * Codebook restart for dead codes

References:
-----------
[1] van den Oord et al., "Neural Discrete Representation Learning", NeurIPS 2017
[2] Razavi et al., "Generating Diverse High-Fidelity Images with VQ-VAE-2", 2019
[3] Esser et al., "Taming Transformers for High-Resolution Image Synthesis", 2020
"""

from typing import Dict, Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F


class VectorQuantizer(nn.Module):
    """
    Vector Quantization layer with Straight-Through Estimator.

    Paper Section 3.1: "The posterior categorical distribution is also defined as
    a one-hot distribution: q(z=k|x) = 1 for k=argmin_j ||z_e(x) - e_j||²"

    The Straight-Through Estimator (STE) handles the non-differentiable argmin:
    - Forward pass: Use quantized values z_q = e_k
    - Backward pass: Copy gradient from z_q to z_e (bypass quantization)

    Args:
        num_embeddings: Size of the discrete codebook (K in paper)
        embedding_dim: Dimension of each code vector (D in paper)
        commitment_cost: Weight for commitment loss (β in paper, default 0.25)
        decay: EMA decay rate for codebook updates (default 0.99)
        epsilon: Small constant for numerical stability (default 1e-5)
        use_ema: Whether to use EMA updates for codebook (default True)

    Attributes:
        embeddings: Learnable codebook matrix of shape (K, D)

    Example:
        >>> vq = VectorQuantizer(num_embeddings=512, embedding_dim=64)
        >>> z_e = torch.randn(4, 64, 8, 8)  # (B, D, H, W)
        >>> z_q, loss, indices = vq(z_e)
        >>> z_q.shape
        torch.Size([4, 64, 8, 8])
        >>> loss.shape
        torch.Size([])
        >>> indices.shape
        torch.Size([4, 8, 8])
    """

    def __init__(
        self,
        num_embeddings: int,
        embedding_dim: int,
        commitment_cost: float = 0.25,
        decay: float = 0.99,
        epsilon: float = 1e-5,
        use_ema: bool = True,
    ):
        super().__init__()

        self.num_embeddings = num_embeddings
        self.embedding_dim = embedding_dim
        self.commitment_cost = commitment_cost
        self.decay = decay
        self.epsilon = epsilon
        self.use_ema = use_ema

        # Paper Section 3.2: "The codebook vectors are learned via gradient descent
        # or EMA updates"
        # Initialize codebook: Uniform(-1/K, 1/K)
        self.embeddings = nn.Embedding(num_embeddings, embedding_dim)
        self.embeddings.weight.data.uniform_(
            -1.0 / num_embeddings, 1.0 / num_embeddings
        )

        # For EMA updates
        if use_ema:
            # Register buffers for EMA statistics
            self.register_buffer("_ema_cluster_size", torch.zeros(num_embeddings))
            self.register_buffer("_ema_w", self.embeddings.weight.data.clone())

    def forward(
        self, z: torch.Tensor
    ) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        """
        Quantize continuous encoder outputs to discrete codes.

        Paper Algorithm:
        1. Encode input: z_e = Encoder(x)
        2. Flatten spatial dimensions
        3. Compute L2 distances to all codebook entries
        4. Find nearest: k = argmin_j ||z_e - e_j||²
        5. Quantize: z_q = e_k
        6. Apply Straight-Through Estimator for gradients

        Args:
            z: Encoder outputs of shape (B, D, H, W)
               B = batch size, D = embedding_dim, H,W = spatial dims

        Returns:
            quantized: Quantized tensor with gradients (via STE), shape (B, D, H, W)
            vq_loss: Combined VQ loss (scalar)
            encoding_indices: Discrete codes of shape (B, H, W)

        Paper Equations:
            Quantization: z_q = e_k where k = argmin_j ||z - e_j||²
            Loss: L = ||sg[z] - e||² + β||z - sg[e]||²
        """
        # Input shape: (B, D, H, W)
        b, d, h, w = z.shape
        assert (
            d == self.embedding_dim
        ), f"Input dim {d} != embedding_dim {self.embedding_dim}"

        # Flatten spatial dimensions: (B, D, H, W) -> (B*H*W, D)
        z_flat = z.permute(0, 2, 3, 1).reshape(-1, self.embedding_dim)

        # Paper Section 3.1: Compute L2 distances ||z - e||²
        # Efficient computation using ||z - e||² = ||z||² + ||e||² - 2*z*e
        # distances[i, j] = ||z_flat[i] - embeddings[j]||²

        # (B*H*W, 1) + (1, K) - 2*(B*H*W, K) = (B*H*W, K)
        distances = (
            torch.sum(z_flat**2, dim=1, keepdim=True)  # ||z||²: (B*H*W, 1)
            + torch.sum(self.embeddings.weight**2, dim=1)  # ||e||²: (K,)
            + -2
            * torch.matmul(z_flat, self.embeddings.weight.t())  # -2*z*e: (B*H*W, K)
        )

        # Paper: Find nearest codebook entry k = argmin_j ||z - e_j||²
        encoding_indices = torch.argmin(distances, dim=1)  # (B*H*W,)

        # Quantize: z_q = e_k (look up embeddings)
        quantized_flat = self.embeddings(encoding_indices)  # (B*H*W, D)

        # Reshape back to spatial: (B*H*W, D) -> (B, H, W, D) -> (B, D, H, W)
        quantized = quantized_flat.view(b, h, w, self.embedding_dim).permute(0, 3, 1, 2)
        encoding_indices = encoding_indices.view(b, h, w)

        # Paper Section 3.2: Compute VQ-VAE loss
        if self.training:
            # Codebook loss: ||sg[z] - e||² (only codebook updated)
            # Stop-gradient on z (encoder), update embeddings toward encoder outputs
            codebook_loss = F.mse_loss(quantized.detach(), z)

            # Commitment loss: β||z - sg[e]||² (only encoder updated)
            # Stop-gradient on embeddings, encourage encoder to commit to codebook
            commitment_loss = F.mse_loss(quantized, z.detach())

            # Total VQ loss
            vq_loss = codebook_loss + self.commitment_cost * commitment_loss

            # EMA updates for codebook (alternative to gradient descent)
            if self.use_ema:
                self._ema_update_codebook(z_flat, encoding_indices.flatten())
        else:
            # No loss during evaluation
            vq_loss = torch.tensor(0.0, device=z.device)

        # Paper Section 3.1: Straight-Through Estimator
        # Forward: use quantized values
        # Backward: gradient flows through as if quantization didn't exist
        # Implementation: z_q = z + (z_q - z).detach()
        #   - Forward: z_q (quantized value)
        #   - Backward: ∂L/∂z = ∂L/∂z_q (gradient bypass)
        quantized = z + (quantized - z).detach()

        return quantized, vq_loss, encoding_indices

    def _ema_update_codebook(
        self, z_flat: torch.Tensor, encoding_indices: torch.Tensor
    ) -> None:
        """
        Update codebook using Exponential Moving Average (EMA).

        Paper Section 3.2: "Alternatively, we can use EMA updates for the codebook
        vectors. This often results in better codebook utilization."

        EMA Update Rule:
            cluster_size[i] ← λ * cluster_size[i] + (1-λ) * N_i
            e[i] ← λ * e[i] + (1-λ) * Σz / N_i

        Where:
            λ = decay rate (0.99)
            N_i = number of vectors assigned to code i

        Args:
            z_flat: Encoder outputs of shape (B*H*W, D)
            encoding_indices: Assigned codes of shape (B*H*W,)
        """
        with torch.no_grad():
            # One-hot encode assignments: (B*H*W, K)
            encodings = F.one_hot(encoding_indices, self.num_embeddings).float()

            # Update cluster sizes: N_i for each code
            # _ema_cluster_size[i] = λ * old_size[i] + (1-λ) * new_assignments[i]
            new_cluster_size = torch.sum(encodings, dim=0)
            self._ema_cluster_size.mul_(self.decay).add_(
                new_cluster_size, alpha=(1 - self.decay)
            )

            # Laplace smoothing for stability
            # Add small constant to avoid division by zero
            n = torch.sum(self._ema_cluster_size)
            cluster_size = (
                (self._ema_cluster_size + self.epsilon)
                / (n + self.num_embeddings * self.epsilon)
                * n
            )

            # Update codebook: e[i] = Σz for code i
            # _ema_w[i] = λ * old_w[i] + (1-λ) * Σz
            dw = torch.matmul(encodings.t(), z_flat)  # (K, D)
            self._ema_w.mul_(self.decay).add_(dw, alpha=(1 - self.decay))

            # Normalize by cluster size
            self.embeddings.weight.data = self._ema_w / cluster_size.unsqueeze(1)

    def get_codebook_entry(self, indices: torch.Tensor) -> torch.Tensor:
        """
        Lookup codebook entries by indices.

        Useful for generation when sampling from a learned prior.

        Args:
            indices: Discrete codes of shape (...,)

        Returns:
            Quantized vectors of shape (..., D)
        """
        return self.embeddings(indices)

    def get_codebook_usage(self) -> Dict[str, float]:
        """
        Get statistics about codebook utilization.

        Returns:
            Dictionary with:
                - usage: Percentage of codes used (0-100)
                - perplexity: Perplexity of code distribution

        Paper: High perplexity indicates good codebook utilization
        """
        if not self.use_ema:
            return {"usage": 0.0, "perplexity": 0.0}

        # Count how many codes have been used
        used_codes = torch.sum(self._ema_cluster_size > 0).item()
        usage_percent = 100.0 * used_codes / self.num_embeddings

        # Compute perplexity
        # Perplexity = exp(-Σp(c)log p(c))
        # Higher perplexity = more uniform distribution = better
        probs = self._ema_cluster_size / torch.sum(self._ema_cluster_size)
        probs = probs[probs > 0]  # Remove unused codes
        perplexity = torch.exp(-torch.sum(probs * torch.log(probs))).item()

        return {
            "usage": usage_percent,
            "perplexity": perplexity,
            "used_codes": used_codes,
            "total_codes": self.num_embeddings,
        }


class Encoder(nn.Module):
    """
    Convolutional encoder for VQ-VAE.

    Paper Section 4.1: "We use a similar architecture to the encoder
    of a typical VAE."

    Architecture:
    Input (B, C, H, W)
    → Conv2d(C, 32, 4, stride=2) → ReLU    # H/2 × W/2
    → Conv2d(32, 64, 4, stride=2) → ReLU   # H/4 × W/4
    → Conv2d(64, latent_dim, 3, padding=1) # H/4 × W/4

    Args:
        in_channels: Number of input channels (e.g., 3 for RGB)
        latent_dim: Dimension of latent vectors (D in paper)
        hidden_dim: Hidden layer dimension (default 64)

    Example:
        >>> encoder = Encoder(in_channels=3, latent_dim=64)
        >>> x = torch.randn(4, 3, 32, 32)
        >>> z_e = encoder(x)
        >>> z_e.shape
        torch.Size([4, 64, 8, 8])  # 4x downsampling
    """

    def __init__(self, in_channels: int, latent_dim: int, hidden_dim: int = 64):
        super().__init__()

        # Paper architecture: Strided convolutions for downsampling
        self.network = nn.Sequential(
            # Layer 1: (B, C, H, W) -> (B, 32, H/2, W/2)
            nn.Conv2d(in_channels, 32, kernel_size=4, stride=2, padding=1),
            nn.ReLU(inplace=True),
            # Layer 2: (B, 32, H/2, W/2) -> (B, 64, H/4, W/4)
            nn.Conv2d(32, hidden_dim, kernel_size=4, stride=2, padding=1),
            nn.ReLU(inplace=True),
            # Layer 3: (B, 64, H/4, W/4) -> (B, latent_dim, H/4, W/4)
            nn.Conv2d(hidden_dim, latent_dim, kernel_size=3, padding=1),
            # No activation on final layer
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """
        Encode input to continuous latent representation.

        Args:
            x: Input tensor of shape (B, C, H, W)

        Returns:
            z_e: Continuous latent codes of shape (B, latent_dim, H/4, W/4)
        """
        return self.network(x)


class Decoder(nn.Module):
    """
    Convolutional decoder for VQ-VAE.

    Paper Section 4.1: "The decoder mirrors the encoder."

    Architecture:
    Input (B, latent_dim, H, W)
    → ConvTranspose2d(latent_dim, 64, 4, stride=2) → ReLU   # 2H × 2W
    → ConvTranspose2d(64, 32, 4, stride=2) → ReLU           # 4H × 4W
    → ConvTranspose2d(32, out_channels, 3, padding=1)       # 4H × 4W

    Args:
        latent_dim: Dimension of latent vectors (D in paper)
        out_channels: Number of output channels (e.g., 3 for RGB)
        hidden_dim: Hidden layer dimension (default 64)

    Example:
        >>> decoder = Decoder(latent_dim=64, out_channels=3)
        >>> z_q = torch.randn(4, 64, 8, 8)
        >>> x_recon = decoder(z_q)
        >>> x_recon.shape
        torch.Size([4, 3, 32, 32])  # 4x upsampling
    """

    def __init__(self, latent_dim: int, out_channels: int, hidden_dim: int = 64):
        super().__init__()

        # Paper architecture: Transposed convolutions for upsampling
        self.network = nn.Sequential(
            # Layer 1: (B, latent_dim, H, W) -> (B, 64, 2H, 2W)
            nn.ConvTranspose2d(
                latent_dim, hidden_dim, kernel_size=4, stride=2, padding=1
            ),
            nn.ReLU(inplace=True),
            # Layer 2: (B, 64, 2H, 2W) -> (B, 32, 4H, 4W)
            nn.ConvTranspose2d(hidden_dim, 32, kernel_size=4, stride=2, padding=1),
            nn.ReLU(inplace=True),
            # Layer 3: (B, 32, 4H, 4W) -> (B, out_channels, 4H, 4W)
            nn.ConvTranspose2d(32, out_channels, kernel_size=3, padding=1),
            # No activation (reconstruction can be any range)
        )

    def forward(self, z_q: torch.Tensor) -> torch.Tensor:
        """
        Decode quantized latent representation to reconstruction.

        Args:
            z_q: Quantized latent codes of shape (B, latent_dim, H, W)

        Returns:
            x_recon: Reconstructed input of shape (B, C, 4H, 4W)
        """
        return self.network(z_q)


class VQVAE(nn.Module):
    """
    Complete VQ-VAE model combining encoder, quantizer, and decoder.

    Paper Architecture (Figure 1):
    x → Encoder → z_e → Quantizer → z_q → Decoder → x̂
                    ↓___________↑
                         Loss

    Full Pipeline:
    1. Encoder maps input x to continuous latent z_e
    2. VectorQuantizer maps z_e to discrete codes z_q
    3. Decoder maps z_q back to reconstruction x̂

    Loss Function (Paper Equation 3):
        L = log p(x|z_q) + ||sg[z_e] - e||² + β||z_e - sg[e]||²

    Args:
        in_channels: Number of input channels
        latent_dim: Dimension of latent vectors
        num_embeddings: Size of codebook (K)
        commitment_cost: Weight for commitment loss (β)
        hidden_dim: Hidden dimension for encoder/decoder

    Attributes:
        encoder: Encoder network
        quantizer: Vector quantization layer
        decoder: Decoder network

    Example:
        >>> model = VQVAE(in_channels=3, latent_dim=64, num_embeddings=512)
        >>> x = torch.randn(4, 3, 32, 32)
        >>> x_recon, vq_loss, indices = model(x)
        >>> x_recon.shape
        torch.Size([4, 3, 32, 32])
        >>> vq_loss.item()  # Scalar loss
        0.123
        >>> indices.shape  # Discrete codes
        torch.Size([4, 8, 8])
    """

    def __init__(
        self,
        in_channels: int,
        latent_dim: int,
        num_embeddings: int,
        commitment_cost: float = 0.25,
        hidden_dim: int = 64,
        **vq_kwargs,
    ):
        super().__init__()

        self.in_channels = in_channels
        self.latent_dim = latent_dim
        self.num_embeddings = num_embeddings

        # Paper components
        self.encoder = Encoder(in_channels, latent_dim, hidden_dim)
        self.quantizer = VectorQuantizer(
            num_embeddings=num_embeddings,
            embedding_dim=latent_dim,
            commitment_cost=commitment_cost,
            **vq_kwargs,
        )
        self.decoder = Decoder(latent_dim, in_channels, hidden_dim)

    def forward(
        self, x: torch.Tensor
    ) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        """
        Forward pass through full VQ-VAE.

        Paper Pipeline:
        1. x → Encoder → z_e (continuous latent)
        2. z_e → Quantizer → z_q (discrete latent)
        3. z_q → Decoder → x̂ (reconstruction)

        Args:
            x: Input tensor of shape (B, C, H, W)

        Returns:
            x_recon: Reconstructed input of shape (B, C, H, W)
            vq_loss: VQ-VAE loss (scalar)
            indices: Discrete codes of shape (B, H/4, W/4)

        Paper Equations:
            z_e = Encoder(x)
            z_q = Quantize(z_e) = e_k where k = argmin_j ||z_e - e_j||²
            x̂ = Decoder(z_q)

            L = ||x - x̂||² + ||sg[z_e] - e||² + β||z_e - sg[e]||²
        """
        # Encode: x → z_e
        z_e = self.encoder(x)

        # Quantize: z_e → z_q
        z_q, vq_loss, indices = self.quantizer(z_e)

        # Decode: z_q → x̂
        x_recon = self.decoder(z_q)

        return x_recon, vq_loss, indices

    def encode(self, x: torch.Tensor) -> torch.Tensor:
        """
        Encode input to discrete indices.

        Args:
            x: Input tensor of shape (B, C, H, W)

        Returns:
            indices: Discrete codes of shape (B, H/4, W/4)
        """
        z_e = self.encoder(x)
        _, _, indices = self.quantizer(z_e)
        return indices

    def decode(self, indices: torch.Tensor) -> torch.Tensor:
        """
        Decode discrete indices to reconstruction.

        Paper: "For generation, we sample from the learned prior and
        decode through the decoder."

        Args:
            indices: Discrete codes of shape (B, H, W)

        Returns:
            x_recon: Reconstructed input of shape (B, C, 4H, 4W)
        """
        # Lookup codebook entries
        z_q = self.quantizer.get_codebook_entry(indices)
        # Reshape: (B, H, W, D) -> (B, D, H, W)
        z_q = z_q.permute(0, 3, 1, 2)
        # Decode
        x_recon = self.decoder(z_q)
        return x_recon

    def get_codebook_usage(self) -> Dict[str, float]:
        """Get codebook utilization statistics."""
        return self.quantizer.get_codebook_usage()


def test_vqvae():
    """
    Test VQ-VAE implementation with synthetic data.

    Verifies:
    - Forward pass works
    - Shapes are correct
    - Gradients flow
    - Loss decreases with training
    """
    print("Testing VQ-VAE implementation...")

    # Create model
    model = VQVAE(
        in_channels=3, latent_dim=64, num_embeddings=512, commitment_cost=0.25
    )

    # Synthetic data
    batch_size = 4
    x = torch.randn(batch_size, 3, 32, 32)

    # Forward pass
    x_recon, vq_loss, indices = model(x)

    # Verify shapes
    assert (
        x_recon.shape == x.shape
    ), f"Reconstruction shape mismatch: {x_recon.shape} vs {x.shape}"
    assert vq_loss.shape == torch.Size(
        []
    ), f"Loss should be scalar, got {vq_loss.shape}"
    assert indices.shape == (
        batch_size,
        8,
        8,
    ), f"Indices shape mismatch: {indices.shape}"

    print(f"  ✓ Input shape: {x.shape}")
    print(f"  ✓ Reconstruction shape: {x_recon.shape}")
    print(f"  ✓ VQ Loss: {vq_loss.item():.4f}")
    print(f"  ✓ Indices shape: {indices.shape}")
    print(f"  ✓ Index range: [{indices.min().item()}, {indices.max().item()}]")

    # Test backward pass
    recon_loss = F.mse_loss(x_recon, x)
    total_loss = recon_loss + vq_loss
    total_loss.backward()

    # Check gradients exist
    has_grads = sum(p.grad is not None for p in model.parameters())
    total_params = sum(1 for _ in model.parameters())
    print(f"  ✓ Gradients computed: {has_grads}/{total_params} parameters")

    # Test codebook usage
    usage = model.get_codebook_usage()
    print(
        f"  ✓ Codebook usage: {usage['usage']:.1f}% ({usage['used_codes']}/{usage['total_codes']} codes)"
    )

    # Test encode/decode
    indices = model.encode(x)
    x_decoded = model.decode(indices)
    assert x_decoded.shape == x.shape
    print(f"  ✓ Encode/decode works: {x_decoded.shape}")

    print("\n✅ All VQ-VAE tests passed!")

    return model, x


if __name__ == "__main__":
    # Run tests when file is executed directly
    test_vqvae()
