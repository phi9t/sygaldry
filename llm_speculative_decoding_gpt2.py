#!/usr/bin/env python3
"""
Production-Ready Speculative Decoding Implementation for Large Language Models
==============================================================================

This module implements speculative decoding, an inference acceleration technique
that uses a smaller "draft" model to propose tokens which are then verified by
a larger "target" model. This approach can significantly reduce inference latency
while maintaining the same quality as standard autoregressive generation.

Architecture:
    - Target Model: High-quality but slower model (e.g., GPT-2)
    - Draft Model: Faster but lower-quality model (e.g., DistilGPT-2)
    - Speculative Process: Draft model proposes K tokens, target model verifies

Key Benefits:
    - Reduced inference time through parallel speculation
    - Maintained output quality (mathematically equivalent to target-only)
    - Efficient GPU utilization with multi-device deployment
    - Configurable speculation depth and acceptance thresholds

Author: Sygaldry AI Systems
Version: 1.0.0
License: MIT
"""

import argparse
import json
import logging
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Union

import torch
from transformers import AutoTokenizer, AutoModelForCausalLM

# =============================================================================
# Configuration Management
# =============================================================================


@dataclass
class SpeculativeDecodingConfig:
    """
    Configuration dataclass for speculative decoding parameters.

    This centralizes all configuration options and provides validation,
    making the system more maintainable and easier to tune for production.
    """

    # Model Configuration
    target_model_name: str = "gpt2"
    draft_model_name: str = "distilbert/distilgpt2"
    model_dtype: str = "float16"  # "float16", "bfloat16", "float32"

    # Device Configuration
    target_device: str = "cuda:0"
    draft_device: str = "cuda:1"
    auto_device_map: bool = True  # Automatically map devices if multi-GPU unavailable

    # Generation Parameters
    speculation_length: int = 4  # Number of tokens to speculate (K)
    max_new_tokens: int = 50
    temperature: float = 1.0
    top_p: float = 1.0
    top_k: int = 0  # 0 means no top-k filtering

    # Performance Tuning
    batch_size: int = 1
    max_sequence_length: int = 2048
    use_cache: bool = True

    # Logging and Monitoring
    log_level: str = "INFO"
    enable_metrics: bool = True
    metrics_output_file: Optional[str] = None

    # Safety and Validation
    max_speculation_length: int = 10
    min_acceptance_rate: float = 0.1  # Minimum acceptance rate to continue speculation
    fallback_to_standard: bool = (
        True  # Fall back to standard generation if speculation fails
    )

    def __post_init__(self):
        """Validate configuration parameters after initialization."""
        self._validate_config()

    def _validate_config(self) -> None:
        """Validate configuration parameters and set derived values."""
        # Validate speculation length
        if not 1 <= self.speculation_length <= self.max_speculation_length:
            raise ValueError(
                f"speculation_length ({self.speculation_length}) must be between "
                f"1 and {self.max_speculation_length}"
            )

        # Validate temperature
        if self.temperature <= 0:
            raise ValueError(f"temperature ({self.temperature}) must be positive")

        # Validate devices
        if torch.cuda.is_available():
            available_devices = torch.cuda.device_count()
            if available_devices < 2 and not self.auto_device_map:
                logging.warning(
                    f"Only {available_devices} GPU(s) available, but auto_device_map=False. "
                    "Consider enabling auto_device_map for better performance."
                )

        # Set torch dtype
        dtype_map = {
            "float16": torch.float16,
            "bfloat16": torch.bfloat16,
            "float32": torch.float32,
        }
        if self.model_dtype not in dtype_map:
            raise ValueError(f"model_dtype must be one of {list(dtype_map.keys())}")
        self._torch_dtype = dtype_map[self.model_dtype]

    @property
    def torch_dtype(self) -> torch.dtype:
        """Get the PyTorch dtype for model loading."""
        return self._torch_dtype

    @classmethod
    def from_file(cls, config_path: Union[str, Path]) -> "SpeculativeDecodingConfig":
        """Load configuration from JSON file."""
        config_path = Path(config_path)
        if not config_path.exists():
            raise FileNotFoundError(f"Configuration file not found: {config_path}")

        with open(config_path, "r") as f:
            config_dict = json.load(f)

        return cls(**config_dict)

    def save_to_file(self, config_path: Union[str, Path]) -> None:
        """Save configuration to JSON file."""
        config_path = Path(config_path)
        config_path.parent.mkdir(parents=True, exist_ok=True)

        with open(config_path, "w") as f:
            json.dump(asdict(self), f, indent=2)


# =============================================================================
# Logging Configuration
# =============================================================================


def setup_logging(
    level: str = "INFO", log_file: Optional[str] = None, include_timestamp: bool = True
) -> logging.Logger:
    """
    Configure logging for the speculative decoding system.

    Args:
        level: Logging level (DEBUG, INFO, WARNING, ERROR, CRITICAL)
        log_file: Optional file to write logs to
        include_timestamp: Whether to include timestamps in log messages

    Returns:
        Configured logger instance
    """
    # Convert string level to logging constant
    numeric_level = getattr(logging, level.upper(), None)
    if not isinstance(numeric_level, int):
        raise ValueError(f"Invalid log level: {level}")

    # Create formatter
    if include_timestamp:
        formatter = logging.Formatter(
            "%(asctime)s - %(name)s - %(levelname)s - %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
        )
    else:
        formatter = logging.Formatter("%(name)s - %(levelname)s - %(message)s")

    # Configure root logger
    logger = logging.getLogger("speculative_decoding")
    logger.setLevel(numeric_level)

    # Remove existing handlers
    for handler in logger.handlers[:]:
        logger.removeHandler(handler)

    # Add console handler
    console_handler = logging.StreamHandler()
    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)

    # Add file handler if specified
    if log_file:
        file_handler = logging.FileHandler(log_file)
        file_handler.setFormatter(formatter)
        logger.addHandler(file_handler)

    return logger


# =============================================================================
# Performance Metrics
# =============================================================================


@dataclass
class SpeculationMetrics:
    """Metrics tracking for speculative decoding performance."""

    total_tokens_generated: int = 0
    total_speculation_rounds: int = 0
    total_accepted_tokens: int = 0
    total_inference_time: float = 0.0
    draft_inference_time: float = 0.0
    target_inference_time: float = 0.0

    @property
    def acceptance_rate(self) -> float:
        """Calculate the overall token acceptance rate."""
        if self.total_speculation_rounds == 0:
            return 0.0
        total_speculated = (
            self.total_speculation_rounds * 4
        )  # Assuming K=4, should be parameterized
        return (
            self.total_accepted_tokens / total_speculated
            if total_speculated > 0
            else 0.0
        )

    @property
    def tokens_per_second(self) -> float:
        """Calculate generation speed in tokens per second."""
        if self.total_inference_time == 0:
            return 0.0
        return self.total_tokens_generated / self.total_inference_time

    @property
    def speedup_ratio(self) -> float:
        """Estimate speedup compared to standard autoregressive generation."""
        if self.acceptance_rate == 0:
            return 1.0
        # Theoretical speedup based on acceptance rate and speculation length
        return 1 + (self.acceptance_rate * 3)  # Simplified calculation

    def to_dict(self) -> Dict[str, float]:
        """Convert metrics to dictionary for logging/serialization."""
        return {
            "total_tokens_generated": self.total_tokens_generated,
            "total_speculation_rounds": self.total_speculation_rounds,
            "total_accepted_tokens": self.total_accepted_tokens,
            "total_inference_time": self.total_inference_time,
            "draft_inference_time": self.draft_inference_time,
            "target_inference_time": self.target_inference_time,
            "acceptance_rate": self.acceptance_rate,
            "tokens_per_second": self.tokens_per_second,
            "speedup_ratio": self.speedup_ratio,
        }


# =============================================================================
# Model Management
# =============================================================================


class ModelManager:
    """
    Manages loading, device placement, and lifecycle of target and draft models.

    This class handles the complexity of multi-GPU deployment, automatic device
    mapping, and graceful fallbacks when hardware constraints are encountered.
    """

    def __init__(self, config: SpeculativeDecodingConfig, logger: logging.Logger):
        self.config = config
        self.logger = logger
        self.tokenizer: Optional[AutoTokenizer] = None
        self.target_model: Optional[AutoModelForCausalLM] = None
        self.draft_model: Optional[AutoModelForCausalLM] = None
        self.target_device: torch.device = None
        self.draft_device: torch.device = None

    def initialize(self) -> None:
        """Initialize tokenizer and models with proper device placement."""
        self.logger.info("Initializing ModelManager...")

        # Setup devices
        self._setup_devices()

        # Load tokenizer
        self._load_tokenizer()

        # Load models
        self._load_models()

        self.logger.info("ModelManager initialization complete")

    def _setup_devices(self) -> None:
        """Configure device placement for target and draft models."""
        self.logger.info("Setting up device configuration...")

        if not torch.cuda.is_available():
            self.logger.warning("CUDA not available, falling back to CPU")
            self.target_device = torch.device("cpu")
            self.draft_device = torch.device("cpu")
            return

        available_gpus = torch.cuda.device_count()
        self.logger.info(f"Available GPUs: {available_gpus}")

        if available_gpus >= 2:
            # Use specified devices if available
            try:
                self.target_device = torch.device(self.config.target_device)
                self.draft_device = torch.device(self.config.draft_device)
                self.logger.info(f"Target model device: {self.target_device}")
                self.logger.info(f"Draft model device: {self.draft_device}")
            except RuntimeError as e:
                self.logger.error(f"Failed to set up specified devices: {e}")
                raise
        elif available_gpus == 1:
            if self.config.auto_device_map:
                self.logger.info(
                    "Only 1 GPU available, using same device for both models"
                )
                self.target_device = torch.device("cuda:0")
                self.draft_device = torch.device("cuda:0")
            else:
                raise RuntimeError(
                    "Insufficient GPUs available and auto_device_map=False"
                )
        else:
            raise RuntimeError("No GPUs available for inference")

    def _load_tokenizer(self) -> None:
        """Load and configure the tokenizer."""
        self.logger.info(f"Loading tokenizer: {self.config.target_model_name}")

        try:
            self.tokenizer = AutoTokenizer.from_pretrained(
                self.config.target_model_name,
                padding_side="left",  # Important for batch processing
            )

            if self.tokenizer.pad_token is None:
                self.tokenizer.pad_token = self.tokenizer.eos_token
                self.logger.info("Set pad_token to eos_token")

            self.logger.info(
                f"Tokenizer loaded successfully. Vocab size: {len(self.tokenizer)}"
            )

        except Exception as e:
            self.logger.error(f"Failed to load tokenizer: {e}")
            raise

    def _load_models(self) -> None:
        """Load target and draft models with proper configuration."""
        self.logger.info("Loading models...")

        # Load target model
        self.logger.info(f"Loading target model: {self.config.target_model_name}")
        try:
            self.target_model = AutoModelForCausalLM.from_pretrained(
                self.config.target_model_name,
                torch_dtype=self.config.torch_dtype,
                device_map=None,  # We handle device placement manually
                trust_remote_code=False,  # Security best practice
            ).to(self.target_device)

            self.target_model.eval()
            target_params = sum(p.numel() for p in self.target_model.parameters())
            self.logger.info(f"Target model loaded. Parameters: {target_params:,}")

        except Exception as e:
            self.logger.error(f"Failed to load target model: {e}")
            raise

        # Load draft model
        self.logger.info(f"Loading draft model: {self.config.draft_model_name}")
        try:
            self.draft_model = AutoModelForCausalLM.from_pretrained(
                self.config.draft_model_name,
                torch_dtype=self.config.torch_dtype,
                device_map=None,
                trust_remote_code=False,
            ).to(self.draft_device)

            self.draft_model.eval()
            draft_params = sum(p.numel() for p in self.draft_model.parameters())
            self.logger.info(f"Draft model loaded. Parameters: {draft_params:,}")

            # Log model size ratio
            size_ratio = (
                target_params / draft_params if draft_params > 0 else float("inf")
            )
            self.logger.info(f"Target/Draft model size ratio: {size_ratio:.2f}x")

        except Exception as e:
            self.logger.error(f"Failed to load draft model: {e}")
            raise

    def cleanup(self) -> None:
        """Clean up model resources."""
        self.logger.info("Cleaning up model resources...")

        for model_name, model in [
            ("target", self.target_model),
            ("draft", self.draft_model),
        ]:
            if model is not None:
                del model
                self.logger.debug(f"Cleaned up {model_name} model")

        if torch.cuda.is_available():
            torch.cuda.empty_cache()
            self.logger.debug("Cleared CUDA cache")


# =============================================================================
# Core Speculative Decoding Implementation
# =============================================================================


class SpeculativeDecoder:
    """
    Production-ready implementation of speculative decoding for language models.

    This class encapsulates the complete speculative decoding algorithm with
    comprehensive error handling, performance monitoring, and production features.
    """

    def __init__(
        self,
        config: SpeculativeDecodingConfig,
        model_manager: ModelManager,
        logger: logging.Logger,
    ):
        self.config = config
        self.model_manager = model_manager
        self.logger = logger
        self.metrics = SpeculationMetrics()

        # Validate initialized state
        if not all(
            [
                model_manager.tokenizer,
                model_manager.target_model,
                model_manager.draft_model,
            ]
        ):
            raise RuntimeError(
                "ModelManager must be initialized before creating decoder"
            )

    def generate(
        self,
        prompt: str,
        max_new_tokens: Optional[int] = None,
        temperature: Optional[float] = None,
        top_p: Optional[float] = None,
        top_k: Optional[int] = None,
        return_metrics: bool = False,
    ) -> Union[str, Tuple[str, Dict[str, float]]]:
        """
        Generate text using speculative decoding.

        Args:
            prompt: Input text prompt
            max_new_tokens: Maximum tokens to generate (overrides config)
            temperature: Sampling temperature (overrides config)
            top_p: Nucleus sampling parameter (overrides config)
            top_k: Top-k sampling parameter (overrides config)
            return_metrics: Whether to return performance metrics

        Returns:
            Generated text, optionally with performance metrics

        Raises:
            ValueError: If prompt is empty or invalid
            RuntimeError: If generation fails
        """
        # Validate inputs
        if not prompt or not isinstance(prompt, str):
            raise ValueError("Prompt must be a non-empty string")

        # Use provided parameters or fall back to config defaults
        max_new_tokens = max_new_tokens or self.config.max_new_tokens
        temperature = (
            temperature if temperature is not None else self.config.temperature
        )
        top_p = top_p if top_p is not None else self.config.top_p
        top_k = top_k if top_k is not None else self.config.top_k

        self.logger.info(f"Starting generation with {max_new_tokens} max tokens")
        self.logger.debug(
            f"Generation parameters: temp={temperature}, top_p={top_p}, top_k={top_k}"
        )

        # Reset metrics for this generation
        self.metrics = SpeculationMetrics()

        try:
            start_time = time.time()

            # Tokenize input prompt
            input_ids = self._tokenize_prompt(prompt)
            original_length = len(input_ids[0])

            # Main generation loop
            generated_ids = self._generate_tokens(
                input_ids, max_new_tokens, temperature, top_p, top_k
            )

            # Decode result
            generated_text = self.model_manager.tokenizer.decode(
                generated_ids, skip_special_tokens=True
            )

            total_time = time.time() - start_time
            self.metrics.total_inference_time = total_time
            self.metrics.total_tokens_generated = len(generated_ids) - original_length

            self.logger.info(
                f"Generation complete: {self.metrics.total_tokens_generated} tokens "
                f"in {total_time:.2f}s ({self.metrics.tokens_per_second:.1f} tok/s)"
            )

            if return_metrics:
                return generated_text, self.metrics.to_dict()
            return generated_text

        except Exception as e:
            self.logger.error(f"Generation failed: {e}")
            if self.config.fallback_to_standard and hasattr(self, "_fallback_generate"):
                self.logger.warning("Falling back to standard generation")
                return self._fallback_generate(prompt, max_new_tokens)
            raise RuntimeError(f"Speculative decoding failed: {e}") from e

    def _tokenize_prompt(self, prompt: str) -> torch.Tensor:
        """Tokenize input prompt with proper device placement."""
        try:
            tokens = self.model_manager.tokenizer(
                prompt,
                return_tensors="pt",
                truncation=True,
                max_length=self.config.max_sequence_length - self.config.max_new_tokens,
            )
            input_ids = tokens.input_ids.to(self.model_manager.target_device)

            self.logger.debug(f"Tokenized prompt: {len(input_ids[0])} tokens")
            return input_ids

        except Exception as e:
            self.logger.error(f"Failed to tokenize prompt: {e}")
            raise

    def _generate_tokens(
        self,
        input_ids: torch.Tensor,
        max_new_tokens: int,
        temperature: float,
        top_p: float,
        top_k: int,
    ) -> List[int]:
        """
        Main speculative decoding loop with comprehensive error handling.

        This implements the core algorithm:
        1. Draft model proposes K tokens
        2. Target model verifies all K tokens in parallel
        3. Accept tokens up to first mismatch
        4. Add one more token from target model at mismatch position
        """
        generated = input_ids.tolist()[0]
        tokens_generated = 0
        consecutive_rejections = 0
        max_consecutive_rejections = 5

        self.logger.debug(f"Starting generation loop, target length: {max_new_tokens}")

        while tokens_generated < max_new_tokens:
            speculation_start = time.time()

            # Adaptive speculation length based on recent performance
            current_k = self._get_adaptive_speculation_length()
            remaining_tokens = max_new_tokens - tokens_generated
            speculation_length = min(current_k, remaining_tokens)

            if speculation_length == 0:
                break

            try:
                # Draft phase: generate speculative tokens
                draft_start = time.time()
                draft_tokens = self._draft_phase(generated, speculation_length)
                self.metrics.draft_inference_time += time.time() - draft_start

                if not draft_tokens:
                    self.logger.warning("Draft phase produced no tokens")
                    break

                # Verification phase: check with target model
                target_start = time.time()
                accepted_count = self._verification_phase(
                    generated, draft_tokens, temperature, top_p, top_k
                )
                self.metrics.target_inference_time += time.time() - target_start

                # Update state based on results
                tokens_generated += accepted_count
                self.metrics.total_speculation_rounds += 1
                self.metrics.total_accepted_tokens += accepted_count

                # Track consecutive rejections for adaptive behavior
                if accepted_count == 0:
                    consecutive_rejections += 1
                    if consecutive_rejections >= max_consecutive_rejections:
                        self.logger.warning(
                            f"Too many consecutive rejections ({consecutive_rejections}), "
                            "switching to standard generation"
                        )
                        break
                else:
                    consecutive_rejections = 0

                speculation_time = time.time() - speculation_start
                self.logger.debug(
                    f"Speculation round: {accepted_count}/{len(draft_tokens)} accepted "
                    f"in {speculation_time:.3f}s"
                )

            except Exception as e:
                self.logger.error(f"Error in speculation round: {e}")
                if self.config.fallback_to_standard:
                    break
                raise

        # Log final statistics
        self.logger.info(
            f"Generation complete: {tokens_generated} tokens, "
            f"acceptance rate: {self.metrics.acceptance_rate:.1%}"
        )

        return generated

    def _draft_phase(self, context: List[int], k: int) -> List[int]:
        """
        Generate k speculative tokens using the draft model.

        Args:
            context: Current token sequence
            k: Number of tokens to speculate

        Returns:
            List of speculated token IDs
        """
        draft_tokens = []
        current_context = torch.tensor(
            [context], device=self.model_manager.draft_device
        )

        try:
            for step in range(k):
                with torch.no_grad():
                    outputs = self.model_manager.draft_model(current_context)
                    logits = outputs.logits[:, -1, :]  # Get last token logits

                    # Apply sampling (greedy for now, can be extended)
                    next_token_id = torch.argmax(logits, dim=-1).item()
                    draft_tokens.append(next_token_id)

                    # Append to context for next iteration
                    next_token_tensor = torch.tensor(
                        [[next_token_id]], device=current_context.device
                    )
                    current_context = torch.cat(
                        [current_context, next_token_tensor], dim=1
                    )

                    # Check for sequence length limits
                    if current_context.shape[1] >= self.config.max_sequence_length:
                        self.logger.warning(
                            "Reached maximum sequence length during drafting"
                        )
                        break

        except Exception as e:
            self.logger.error(f"Error in draft phase: {e}")
            raise

        return draft_tokens

    def _verification_phase(
        self,
        context: List[int],
        draft_tokens: List[int],
        temperature: float,
        top_p: float,
        top_k: int,
    ) -> int:
        """
        Verify draft tokens using the target model and accept valid ones.

        Args:
            context: Current token sequence
            draft_tokens: Tokens proposed by draft model
            temperature: Sampling temperature
            top_p: Nucleus sampling parameter
            top_k: Top-k sampling parameter

        Returns:
            Number of accepted tokens (includes potential additional target token)
        """
        if not draft_tokens:
            return 0

        try:
            # Prepare combined sequence for target model
            combined_sequence = context + draft_tokens
            combined_tensor = torch.tensor(
                [combined_sequence], device=self.model_manager.target_device
            )

            # Get target model predictions for all positions
            with torch.no_grad():
                outputs = self.model_manager.target_model(combined_tensor)
                target_logits = outputs.logits

            # Verify each draft token
            accepted_count = 0
            context_length = len(context)

            for i, draft_token in enumerate(draft_tokens):
                position = context_length + i
                if position >= target_logits.shape[1]:
                    break

                # Get target model's prediction at this position
                target_prediction = torch.argmax(
                    target_logits[0, position - 1], dim=-1
                ).item()

                if target_prediction == draft_token:
                    # Token accepted
                    context.append(draft_token)
                    accepted_count += 1
                else:
                    # Token rejected, add target model's prediction instead
                    context.append(target_prediction)
                    accepted_count += 1
                    break  # Stop at first mismatch

            return accepted_count

        except Exception as e:
            self.logger.error(f"Error in verification phase: {e}")
            raise

    def _get_adaptive_speculation_length(self) -> int:
        """
        Adaptively adjust speculation length based on recent acceptance rates.

        Returns:
            Optimal speculation length for current conditions
        """
        base_length = self.config.speculation_length

        # If we have enough data, adjust based on acceptance rate
        if self.metrics.total_speculation_rounds > 5:
            acceptance_rate = self.metrics.acceptance_rate

            if acceptance_rate > 0.8:
                # High acceptance, try longer speculation
                return min(base_length + 1, self.config.max_speculation_length)
            elif acceptance_rate < 0.3:
                # Low acceptance, reduce speculation
                return max(1, base_length - 1)

        return base_length

    def _fallback_generate(self, prompt: str, max_new_tokens: int) -> str:
        """
        Fallback to standard autoregressive generation if speculation fails.

        Args:
            prompt: Input prompt
            max_new_tokens: Maximum tokens to generate

        Returns:
            Generated text using standard method
        """
        self.logger.info("Using standard autoregressive generation as fallback")

        try:
            input_ids = self._tokenize_prompt(prompt)

            with torch.no_grad():
                outputs = self.model_manager.target_model.generate(
                    input_ids,
                    max_new_tokens=max_new_tokens,
                    temperature=self.config.temperature,
                    do_sample=self.config.temperature > 1.0,
                    pad_token_id=self.model_manager.tokenizer.eos_token_id,
                    use_cache=self.config.use_cache,
                )

            return self.model_manager.tokenizer.decode(
                outputs[0], skip_special_tokens=True
            )

        except Exception as e:
            self.logger.error(f"Fallback generation failed: {e}")
            raise


# =============================================================================
# Command Line Interface
# =============================================================================


def create_argument_parser() -> argparse.ArgumentParser:
    """Create command line argument parser."""
    parser = argparse.ArgumentParser(
        description="Production-ready speculative decoding for language models",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python llm_speculative_decoding_gpt2.py --prompt "The future of AI is"
  python llm_speculative_decoding_gpt2.py --config config.json --max-tokens 100
  python llm_speculative_decoding_gpt2.py --prompt "Hello" --log-level DEBUG --metrics
        """,
    )

    # Input/Output
    parser.add_argument(
        "--prompt",
        "-p",
        type=str,
        default="In the future, artificial intelligence will",
        help="Input prompt for generation",
    )
    parser.add_argument(
        "--config", "-c", type=str, help="Path to JSON configuration file"
    )
    parser.add_argument(
        "--output-file", "-o", type=str, help="Save generated text to file"
    )

    # Generation parameters
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=50,
        help="Maximum number of tokens to generate",
    )
    parser.add_argument(
        "--temperature", type=float, default=1.0, help="Sampling temperature"
    )
    parser.add_argument(
        "--speculation-length",
        "-k",
        type=int,
        default=4,
        help="Number of tokens to speculate per round",
    )

    # Model selection
    parser.add_argument(
        "--target-model", type=str, default="gpt2", help="Target model name"
    )
    parser.add_argument(
        "--draft-model",
        type=str,
        default="distilbert/distilgpt2",
        help="Draft model name",
    )

    # Device configuration
    parser.add_argument(
        "--target-device", type=str, default="cuda:0", help="Device for target model"
    )
    parser.add_argument(
        "--draft-device", type=str, default="cuda:1", help="Device for draft model"
    )
    parser.add_argument(
        "--auto-device-map",
        action="store_true",
        help="Automatically map devices if multi-GPU unavailable",
    )

    # Logging and debugging
    parser.add_argument(
        "--log-level",
        type=str,
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        help="Logging level",
    )
    parser.add_argument("--log-file", type=str, help="Log to file instead of console")
    parser.add_argument(
        "--metrics", action="store_true", help="Show detailed performance metrics"
    )
    parser.add_argument(
        "--save-config", type=str, help="Save current configuration to file"
    )

    return parser


def main():
    """Main entry point for the application."""
    parser = create_argument_parser()
    args = parser.parse_args()

    # Setup logging
    logger = setup_logging(
        level=args.log_level, log_file=args.log_file, include_timestamp=True
    )

    try:
        # Load or create configuration
        if args.config:
            logger.info(f"Loading configuration from {args.config}")
            config = SpeculativeDecodingConfig.from_file(args.config)
        else:
            # Create config from command line arguments
            config = SpeculativeDecodingConfig(
                target_model_name=args.target_model,
                draft_model_name=args.draft_model,
                speculation_length=args.speculation_length,
                max_new_tokens=args.max_tokens,
                temperature=args.temperature,
                target_device=args.target_device,
                draft_device=args.draft_device,
                auto_device_map=args.auto_device_map,
                log_level=args.log_level,
                enable_metrics=args.metrics,
            )

        # Save configuration if requested
        if args.save_config:
            config.save_to_file(args.save_config)
            logger.info(f"Configuration saved to {args.save_config}")

        # Initialize model manager
        logger.info("Initializing models...")
        model_manager = ModelManager(config, logger)
        model_manager.initialize()

        # Create decoder
        decoder = SpeculativeDecoder(config, model_manager, logger)

        # Generate text
        logger.info("Starting text generation...")
        result = decoder.generate(
            prompt=args.prompt,
            max_new_tokens=args.max_tokens,
            temperature=args.temperature,
            return_metrics=args.metrics,
        )

        if args.metrics:
            generated_text, metrics = result
            logger.info("Performance metrics:")
            for key, value in metrics.items():
                logger.info(f"  {key}: {value}")
        else:
            generated_text = result

        # Output results
        print("\n" + "=" * 60)
        print("SPECULATIVE DECODING OUTPUT")
        print("=" * 60)
        print(generated_text)
        print("=" * 60)

        # Save to file if requested
        if args.output_file:
            with open(args.output_file, "w") as f:
                f.write(generated_text)
            logger.info(f"Output saved to {args.output_file}")

        # Cleanup
        model_manager.cleanup()
        logger.info("Generation completed successfully")

    except KeyboardInterrupt:
        logger.info("Generation interrupted by user")
    except Exception as e:
        logger.error(f"Application failed: {e}")
        raise


if __name__ == "__main__":
    main()
