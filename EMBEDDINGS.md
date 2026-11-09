# Embeddings available on macOS

ArchScan does not use embeddings yet. This note records what macOS offers for
them out of the box, so the choice is already mapped when the Texts, Summaries
and Diagrams sections need search or similarity.

An embedding turns an image or a piece of text into a list of numbers, such
that similar inputs get lists that are close together. Everything below is
part of macOS: no package dependencies, and it runs on the machine.

Measured on 2026-11-09, on macOS 27.2 with Swift 6.4.2.

## The options

| | Framework | API | Input | Output | Measured here |
|---|---|---|---|---|---|
| Image embedding | Vision | `VNGenerateImageFeaturePrintRequest` | an image | one vector of 768 floats | similar pictures 0.09 apart, different ones 0.85 |
| Sentence embedding | NaturalLanguage | `NLEmbedding.sentenceEmbedding(for:)` | a string | one vector of 512 doubles | same-meaning sentences 0.76 apart, unrelated 1.24 |
| Contextual embedding | NaturalLanguage | `NLContextualEmbedding` | a string of up to 256 tokens | one vector of 512 doubles per token | model already installed on this Mac |

Vision only embeds images. Text embeddings come from the NaturalLanguage
framework, which is a separate part of macOS.

## Image embedding: Vision feature prints

Vision calls an image embedding a "feature print". It describes how a picture
looks, not what any text in it says.

```swift
import Vision

func featurePrint(_ image: CGImage) throws -> VNFeaturePrintObservation {
    let request = VNGenerateImageFeaturePrintRequest()
    try VNImageRequestHandler(cgImage: image).perform([request])
    return request.results!.first!
}

var distance: Float = 0
try featurePrint(a).computeDistance(&distance, to: featurePrint(b))
```

- **Output:** `elementCount` was 768 and `elementType` was float.
- **Comparing:** `computeDistance` is built in. Lower means more alike.
- **Measured:** two drawings of four boxes in slightly different colours were
  0.090 apart. A drawing of one box in a different colour was 0.847 away.

In ArchScan this fits the Files, Crops and Diagrams sections: finding diagrams
or crops that look alike, or spotting near-duplicates that the SHA-256 check
misses because the bytes differ.

## Sentence embedding: `NLEmbedding`

The simple text option. One string in, one vector out.

```swift
import NaturalLanguage

let sentences = NLEmbedding.sentenceEmbedding(for: .english)!   // nil if the language is unsupported
let vector = sentences.vector(for: "The API gateway routes requests.")   // [Double]?, 512 numbers
let distance = sentences.distance(between: first, and: second)
```

- **Output:** `dimension` was 512.
- **Comparing:** `distance(between:and:)` is built in. Lower means closer in
  meaning.
- **The built-in distance is not plain cosine distance.** On the measurements
  below it equals the square root of twice the cosine distance, which is the
  straight-line distance between the two vectors after scaling each to length
  one. It ranks pairs the same way cosine distance does; just don't mix the
  two scales.

## Contextual embedding: `NLContextualEmbedding`

The newer option, backed by a transformer model. It returns a vector for every
token rather than one for the whole string, so getting a single vector for a
passage is an extra step. Averaging the token vectors is the usual way:

```swift
import NaturalLanguage

func passageVector(_ text: String, using model: NLContextualEmbedding) throws -> [Double] {
    let result = try model.embeddingResult(for: text, language: .english)
    var sum = [Double](repeating: 0, count: model.dimension)
    var count = 0
    result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
        for (index, value) in vector.enumerated() { sum[index] += value }
        count += 1
        return true
    }
    return sum.map { $0 / Double(max(count, 1)) }
}

let model = NLContextualEmbedding(language: .english)!
try model.load()
let vector = try passageVector("The API gateway routes requests.", using: model)
```

- **Output:** `dimension` was 512. A nine-word sentence produced 18 token
  vectors.
- **Length limit:** `maximumSequenceLength` was 256 tokens. Longer text has to
  be split into chunks first.
- **Comparing:** nothing is built in. Compute cosine distance yourself.
- **Model files:** `hasAvailableAssets` was true here, so the model was
  already installed. The API has `requestAssets` for a Mac where it is not.

## The two text options on the same sentences

Both were given these three sentences, comparing the first against the other
two:

1. "The API gateway routes requests to the order service."
2. "Incoming calls are forwarded by the gateway to the service that handles orders." (same meaning as 1)
3. "Thank you for purchasing this sampler." (unrelated)

| | Same meaning (1 vs 2) | Unrelated (1 vs 3) | Ratio |
|---|---|---|---|
| Sentence embedding, built-in distance | 0.759 | 1.237 | 1.6 |
| Sentence embedding, cosine distance | 0.288 | 0.766 | 2.7 |
| Contextual embedding, averaged, cosine distance | 0.055 | 0.155 | 2.8 |

Both put the paraphrase clearly closer than the unrelated sentence, and by
about the same factor once measured the same way. One example cannot pick a
winner. Note how small the contextual distances are in absolute terms: with
that model, compare distances against each other and rank results, rather
than applying a fixed cut-off.

## What these measurements do and don't show

- **They are toy inputs.** Three sentences and three generated drawings show
  that the APIs work on this machine and roughly how the numbers behave. They
  say nothing yet about search quality on real extracted texts or real
  diagrams.
- **Only English was tried.** Both text APIs take a language and return nil
  when it is unsupported.
- **The models belong to macOS.** A system update can change them, and vectors
  from different model versions should not be compared with each other. If
  vectors are stored, store what produced them alongside (for the contextual
  model, its `modelIdentifier`) and re-embed when that changes.

## If ArchScan adopts this

A suggestion, not something that is built:

- **Texts:** split each extracted text into sentences or paragraphs, embed
  each one, and store the vector as a BLOB in a new SQLite table keyed to the
  text. The sentence embedding is the least work; the contextual model needs
  the averaging and chunking steps above.
- **Crops and diagrams:** store a Vision feature print per image the same way.
- **Searching:** the SQLite that ships with macOS has no vector index.
  Loading the vectors and comparing in a loop is enough at this scale: ten
  thousand 512-number vectors is about five million multiplications per
  query.
