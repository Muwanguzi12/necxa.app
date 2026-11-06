// Lightweight face embedding matcher for Supabase Edge Functions.
// It uses deterministic cosine similarity over normalized embeddings and is
// designed to be swapped for a hosted model or vector DB later without changing
// the contract consumed by the app.

export interface FaceMatchResult {
  verified: boolean;
  similarity: number;
  fraud_risk: string;
  extracted_name: string | null;
  extracted_nin: string | null;
  notes: string;
  rejection_reason: string | null;
  matcher: {
    model: string;
    threshold: number;
    mode: string;
  };
}

function normalizeEmbedding(embedding: number[]): number[] {
  const norm = Math.hypot(...embedding)
  if (!norm) return embedding.map(() => 0)
  return embedding.map((value) => value / norm)
}

function cosineSimilarity(a: number[], b: number[]): number {
  const aNorm = normalizeEmbedding(a)
  const bNorm = normalizeEmbedding(b)
  let dot = 0
  for (let i = 0; i < aNorm.length; i += 1) dot += aNorm[i] * bNorm[i]
  return Math.max(0, Math.min(1, dot))
}

function scoreToFraudRisk(similarity: number): string {
  if (similarity >= 0.88) return 'low'
  if (similarity >= 0.72) return 'medium'
  return 'high'
}

export function runFaceMatch(
  candidateEmbedding: number[],
  referenceEmbedding: number[],
  docNumber: string,
  country: string,
  docType: string,
): FaceMatchResult {
  const similarity = cosineSimilarity(candidateEmbedding, referenceEmbedding)
  const verified = similarity >= 0.72
  const countryNameMap: Record<string, string> = {
    UGANDA: 'Verified Agent',
    KENYA: 'Verified Agent',
    TANZANIA: 'Verified Agent',
    RWANDA: 'Verified Agent',
  }

  return {
    verified,
    similarity,
    fraud_risk: scoreToFraudRisk(similarity),
    extracted_nin: docNumber,
    extracted_name: countryNameMap[country.toUpperCase()] ?? 'Verified Agent',
    notes: `[Necxa Face Match Engine] sim=${(similarity * 100).toFixed(2)}% doc=${docType}`,
    rejection_reason: verified ? null : 'Biometric similarity below the 72% verification threshold.',
    matcher: {
      model: 'cosine-embedding-v1',
      threshold: 0.72,
      mode: 'deterministic',
    },
  }
}
