import torch
from torch import nn

################################################################################
# SimpleTransformerLM: A Minimal Transformer-based Language Model
################################################################################


class SimpleTransformerLM(nn.Module):
    """
    A minimal implementation of a Transformer-based language model for educational purposes.

    This model consists of:
      - Token embedding layer: maps token indices to dense vectors.
      - Positional embedding layer: encodes the position of each token in the sequence.
      - Transformer encoder: processes the embedded sequence.
      - Output head: projects the final hidden states to vocabulary logits.

    Args:
        vocab_size (int): Number of tokens in the vocabulary.
        d_model (int): Dimensionality of the embeddings and hidden states.
        nhead (int): Number of attention heads in the Transformer.
        num_layers (int): Number of Transformer encoder layers.
        dim_feedforward (int): Size of the feedforward network in each encoder layer.
    """

    def __init__(self, vocab_size, d_model, nhead, num_layers, dim_feedforward=128):
        super().__init__()
        # Token embedding: maps token indices to vectors
        self.embedding = nn.Embedding(vocab_size, d_model)
        # Positional embedding: encodes position information (max length 512)
        self.pos_embedding = nn.Embedding(512, d_model)
        # Transformer encoder: stack of self-attention + feedforward layers
        encoder_layer = nn.TransformerEncoderLayer(
            d_model=d_model, nhead=nhead, dim_feedforward=dim_feedforward
        )
        self.transformer = nn.TransformerEncoder(encoder_layer, num_layers=num_layers)
        # Output head: projects hidden states to logits over the vocabulary
        self.output_head = nn.Linear(d_model, vocab_size)

    def forward(self, tokens: torch.Tensor) -> torch.Tensor:
        """
        Forward pass of the language model.

        Args:
            tokens (torch.Tensor): 1D tensor of token indices (sequence length,).

        Returns:
            torch.Tensor: Logits for each position (sequence length, vocab_size).
        """
        seq_len = tokens.size(0)
        # Create position indices [0, 1, ..., seq_len-1]
        positions = torch.arange(seq_len, device=tokens.device)
        # Add token and positional embeddings
        x = self.embedding(tokens) + self.pos_embedding(positions)
        # Transformer expects (sequence, batch, features); add batch dim
        x = self.transformer(x.unsqueeze(1)).squeeze(1)
        # Project to vocabulary logits
        return self.output_head(x)


################################################################################
# Greedy Decoding: Standard Token-by-Token Generation
################################################################################


def greedy_decode(model: nn.Module, context, max_new_tokens):
    """
    Naive greedy decoding: generates tokens one at a time, always picking the most likely next token.

    Args:
        model (nn.Module): The language model to use for generation.
        context (list[int]): List of token indices to start from.
        max_new_tokens (int): Number of tokens to generate.

    Returns:
        tuple: (generated_tokens, num_model_calls)
            - generated_tokens (list[int]): The new tokens generated (not including the context).
            - num_model_calls (int): Number of times the model was called.
    """
    tokens = list(context)  # Copy context to avoid modifying input
    calls = 0
    for _ in range(max_new_tokens):
        # Run the model on the current sequence
        logits = model(torch.tensor(tokens))
        calls += 1
        # Pick the most likely next token (greedy)
        next_token = int(torch.argmax(logits[-1]))
        tokens.append(next_token)
    # Return only the newly generated tokens (not the context)
    return tokens[len(context) :], calls


################################################################################
# Speculative Decoding: Efficient Generation with a Draft Model
################################################################################


def speculative_decode(target: nn.Module, draft: nn.Module, context, max_new_tokens, k):
    """
    Speculative decoding: accelerates generation by using a fast "draft" model to propose multiple tokens,
    then verifying them in bulk with the slower, more accurate "target" model.

    The process:
      1. Use the draft model to greedily propose up to k tokens.
      2. Run the target model once on the full sequence (context + generated + guesses).
      3. Accept as many draft tokens as match the target model's greedy predictions.
      4. If a mismatch occurs, generate the next token from the target model and continue.

    Args:
        target (nn.Module): The accurate (but slow) language model.
        draft (nn.Module): The fast, approximate model for proposing tokens.
        context (list[int]): List of token indices to start from.
        max_new_tokens (int): Number of tokens to generate.
        k (int): Number of draft tokens to propose per speculative step.

    Returns:
        tuple: (generated_tokens, num_target_calls, acceptance_stats)
            - generated_tokens (list[int]): The new tokens generated (not including the context).
            - num_target_calls (int): Number of times the target model was called.
            - acceptance_stats (dict): Statistics about acceptance rates and steps.
    """
    generated = []  # List to store generated tokens (not including context)
    target_calls = 0  # Counter for target model calls
    context_len = len(context)

    # Statistics tracking
    total_guesses = 0
    total_accepted = 0
    acceptance_steps = []

    while len(generated) < max_new_tokens:
        # -------------------------------
        # 1. Draft phase: propose up to k tokens using the draft model
        # -------------------------------
        guesses = []
        draft_input = torch.tensor(context + generated)
        for _ in range(k):
            logits = draft(draft_input)
            # Greedily pick the most likely next token
            guess = int(torch.argmax(logits[-1]))
            guesses.append(guess)
            # Append the guess to the input for the next draft step
            draft_input = torch.cat([draft_input, torch.tensor([guess])])
            # Stop if we've reached the desired total number of tokens
            if len(generated) + len(guesses) >= max_new_tokens:
                break

        # -------------------------------
        # 2. Verification phase: check guesses with the target model
        # -------------------------------
        # Run the target model once on the full sequence (context + generated + guesses)
        full_sequence = context + generated + guesses
        logits = target(torch.tensor(full_sequence))
        target_calls += 1

        # Determine how many draft guesses match the target model's greedy predictions
        offset = context_len + len(generated)  # Start of guesses in logits
        accepted = 0
        acceptance_details = []

        for i, g in enumerate(guesses):
            # For each guess, get the target model's prediction at that position
            target_pred = int(torch.argmax(logits[offset + i]))
            is_accepted = target_pred == g
            acceptance_details.append(
                {
                    "position": len(generated) + i,
                    "draft_guess": g,
                    "target_prediction": target_pred,
                    "accepted": is_accepted,
                }
            )

            if is_accepted:
                accepted += 1  # Accept if it matches
            else:
                break  # Stop at first mismatch

        # Track statistics
        total_guesses += len(guesses)
        total_accepted += accepted
        acceptance_steps.append(
            {
                "step": len(acceptance_steps) + 1,
                "guesses": guesses,
                "accepted": accepted,
                "acceptance_rate": accepted / len(guesses) if guesses else 0,
                "details": acceptance_details,
            }
        )

        # Append all accepted guesses to the generated sequence
        generated.extend(guesses[:accepted])

        # -------------------------------
        # 3. If a mismatch occurred (or if we need more tokens), generate one from target
        # -------------------------------
        if len(generated) < max_new_tokens:
            # The next token to generate is at position (context + generated)
            position = context_len + len(generated)
            token = int(torch.argmax(logits[position]))
            generated.append(token)

    # Compile acceptance statistics
    acceptance_stats = {
        "total_guesses": total_guesses,
        "total_accepted": total_accepted,
        "overall_acceptance_rate": (
            total_accepted / total_guesses if total_guesses > 0 else 0
        ),
        "acceptance_steps": acceptance_steps,
        "target_calls": target_calls,
    }

    return generated, target_calls, acceptance_stats


################################################################################
# Example Usage: Comparing Greedy and Speculative Decoding
################################################################################

if __name__ == "__main__":
    # Set random seed for reproducibility
    torch.manual_seed(0)

    # Define vocabulary size and model hyperparameters
    vocab_size = 50
    d_model = 64
    nhead = 4

    # Create the target (accurate) and draft (fast) models with identical architecture
    target_model = SimpleTransformerLM(
        vocab_size, d_model=d_model, nhead=nhead, num_layers=2
    )
    draft_model = SimpleTransformerLM(
        vocab_size, d_model=d_model, nhead=nhead, num_layers=2
    )

    # Initialize draft model with the same weights as target model
    # Since both models have identical architecture, we can copy all weights
    with torch.no_grad():
        target_state_dict = target_model.state_dict()
        draft_model.load_state_dict(target_state_dict)

    # For demonstration, share embeddings and output head weights so the draft model
    # is a good approximation of the target (makes speculative decoding more effective)
    draft_model.embedding = target_model.embedding
    draft_model.pos_embedding = target_model.pos_embedding
    draft_model.output_head = target_model.output_head

    # Set both models to evaluation mode (disables dropout, etc.)
    target_model.eval()
    draft_model.eval()

    # Define the context (prompt) and decoding parameters
    context = [10, 20]  # Start sequence (token indices)
    max_new_tokens = 20  # How many tokens to generate
    k = 4  # Number of draft guesses per speculative step

    # Run naive greedy decoding (calls the target model once per token)
    naive_tokens, naive_calls = greedy_decode(target_model, context, max_new_tokens)

    # Run speculative decoding (calls the target model less frequently)
    spec_tokens, spec_calls, acceptance_stats = speculative_decode(
        target_model, draft_model, context, max_new_tokens, k
    )

    # Print results for comparison
    print("Naively generated tokens:", naive_tokens)
    print("Target model calls (naive):", naive_calls)
    print("Speculatively generated tokens:", spec_tokens)
    print("Target model calls (speculative):", spec_calls)

    # Print acceptance statistics
    print("\n" + "=" * 50)
    print("SPECULATIVE DECODING ACCEPTANCE STATISTICS")
    print("=" * 50)
    print(f"Overall acceptance rate: {acceptance_stats['overall_acceptance_rate']:.2%}")
    print(f"Total guesses: {acceptance_stats['total_guesses']}")
    print(f"Total accepted: {acceptance_stats['total_accepted']}")
    print(f"Target model calls: {acceptance_stats['target_calls']}")

    print("\nAcceptance steps:")
    for step in acceptance_stats["acceptance_steps"]:
        print(
            f"  Step {step['step']}: {step['accepted']}/{len(step['guesses'])} accepted "
            f"({step['acceptance_rate']:.2%})"
        )
        for detail in step["details"]:
            status = "✓" if detail["accepted"] else "✗"
            print(
                f"    {status} Position {detail['position']}: "
                f"Draft guessed {detail['draft_guess']}, "
                f"Target predicted {detail['target_prediction']}"
            )

    # Output explanation:
    # - The two generated sequences should be similar (since draft ≈ target).
    # - Speculative decoding should require fewer target model calls than naive decoding.
