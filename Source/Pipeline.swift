//
//  Pipeline.swift
//  Siesta
//
//  Created by Paul on 2016/6/3.
//  Copyright © 2016 Bust Out Solutions. All rights reserved.
//

import Foundation


/**
  A sequence of transformation and cache operations that Siesta applies to server responses. A raw response comes in the
  pipeline, and the appropriate data structure for your app comes out the other end. Apps may optionally cache responses
  in one or more of their intermediate forms along the way.

  A pipeline has sequence of **stages**, each of which is uniquely identified by a `PipelineStageKey`. Apps can create
  custom stages, and customize their order. Each stage has zero or more `ResponseTransformer`s, followed by an optional
  `EntityCache`.

  The pipeline is a part of a `Configuration`, so you can thus customize the pipeline per API or per resource.

      service.configure {
        $0.config.pipeline[.parsing].add(SwiftyJSONTransformer, contentTypes: ["*​/json"])
        $0.config.pipeline[.cleanup].add(GithubErrorMessageExtractor())
        $0.config.pipeline[.model].cache = myRealmCache
      }

      service.configureTransformer("/item/​*") {  // Replaces .model stage by default
        Item(json: $0.content)
      }

  By default, Siesta pipelines start with parsers for common data types (JSON, text, image) configured at the
  `PipelineStageKey.parsing` stage. You can remove these default transformers for individual configurations using calls
  such as `clear()` and `removeAllTransformers()`, or you can disable these default parsers entirely by passing
  `useDefaultTransformers: false` when creating a `Service`.

  Services do not have any persistent caching by default.
*/
public struct Pipeline
    {
    private var stages: [PipelineStageKey:PipelineStage] = [:]

    private var stagesInOrder: [PipelineStage]
        { return order.flatMap { stages[$0] } }

    /**
      The order in which the pipeline’s stages run. The default order is:

      1. `PipelineStageKey.rawData`
      2. `decoding`
      3. `parsing`
      4. `model`
      5. `cleanup`

      Stage keys do not have semantic significance — they are just arbitrary identifiers — so you are free arbitrarily
      add or reorder stages if you have complex response processing needs.

      - Note: Stages **must** be unique. Adding a duplicate stage key will cause a precondition failure.
      - Note: Any stage not present in the order will not run, even if it has transformers and/or cache configured.
    */
    public var order: [PipelineStageKey] = [.rawData, .decoding, .parsing, .model, .cleanup]
        {
        willSet
            {
            precondition(
                newValue.count == Set(newValue).count,
                "Pipeline.order contains duplicates: \(newValue)")

            let nonEmptyStages = stages
                .filter { _, stage in !stage.isEmpty }
                .map { key, _ in key }
            let missingStages = Set(nonEmptyStages).subtract(newValue)
            if !missingStages.isEmpty
                { debugLog(.ResponseProcessing, ["WARNING: Stages", missingStages, "configured but not present in custom pipeline order, will be ignored:", newValue]) }
            }
        }

    /**
      Retrieves the stage for the given key, or an empty one if none yet exists.
    */
    public subscript(key: PipelineStageKey) -> PipelineStage
        {
        get { return stages[key] ?? PipelineStage() }
        set { stages[key] = newValue }
        }

    internal var containsCaches: Bool
        { return stages.any { $1.cacheBox != nil } }

    /**
      Removes all transformers from all stages in the pipeline. Leaves caches intact.
    */
    public mutating func removeAllTransformers()
        {
        for key in stages.keys
            { stages[key]?.removeTransformers() }
        }

    /**
      Removes all caches from all stages in the pipeline. Leaves transformers intact.

      You can use this to prevent sensitive resources from being cached:

          configure("/secret") { $0.config.pipeline.removeAllCaches() }
    */
    public mutating func removeAllCaches()
        {
        for key in stages.keys
            { stages[key]?.doNotCache() }
        }

    /**
      Removes all transformers and caches from all stages in the pipeline.
    */
    public mutating func clear()
        {
        removeAllTransformers()
        removeAllCaches()
        }
    }

internal extension Pipeline
    {
    private typealias StageAndEntry = (PipelineStage, CacheEntryProtocol?)

    private func stagesAndEntries(for resource: Resource) -> [StageAndEntry]
        {
        return stagesInOrder.map
            { stage in (stage, stage.cacheBox?.buildEntry(resource)) }
        }

    internal func makeProcessor(rawResponse: Response, resource: Resource) -> Void -> Response
        {
        // Generate cache keys on main queue
        let stagesAndEntries = self.stagesAndEntries(for: resource)

        // Return deferred processor for background queue
        return { self.processAndCache(rawResponse, using: stagesAndEntries) }
        }

    private func processAndCache<StagesAndEntries: CollectionType where StagesAndEntries.Generator.Element == StageAndEntry>(
            rawResponse: Response,
            using stagesAndEntries: StagesAndEntries)
        -> Response
        {
        return stagesAndEntries.reduce(rawResponse)
            {
            let input = $0, (stage, cacheEntry) = $1

            let output = stage.process(input)

            if case .Success(let entity) = output
                {
                debugLog(.Cache, ["Caching entity with", entity.content.dynamicType, "content in", cacheEntry])
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0))
                    { cacheEntry?.write(entity) }
                }

            return output
            }
        }

    internal func cachedEntity(for resource: Resource, onHit: (Entity) -> ())
        {
        // Extract cache keys on main queue
        let stagesAndEntries = self.stagesAndEntries(for: resource)

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0))
            {
            if let entity = self.cacheLookup(using: stagesAndEntries)
                {
                dispatch_async(dispatch_get_main_queue())
                    { onHit(entity) }
                }
            }
        }

    private func cacheLookup(using stagesAndEntries: [StageAndEntry]) -> Entity?
        {
        for (index, (_, cacheEntry)) in stagesAndEntries.enumerate().reverse()
            {
            if let result = cacheEntry?.read()
                {
                debugLog(.Cache, ["Cache hit for", cacheEntry])

                let processed = processAndCache(
                    .Success(result),
                    using: stagesAndEntries.suffixFrom(index + 1))

                switch(processed)
                    {
                    case .Failure:
                        debugLog(.Cache, ["Error processing cached entity; will ignore cached value. Error:", processed])

                    case .Success(let entity):
                        return entity
                    }
                }
            }
        return nil
        }

    internal func updateCacheEntryTimestamps(timestamp: NSTimeInterval, for resource: Resource)
        {
        let stagesAndEntries = self.stagesAndEntries(for: resource)

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0))
            {
            for (_, cacheEntry) in stagesAndEntries
                { cacheEntry?.updateTimestamp(timestamp) }
            }
        }

    internal func removeCacheEntries(for resource: Resource)
        {
        let stagesAndEntries = self.stagesAndEntries(for: resource)

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0))
            {
            for (_, cacheEntry) in stagesAndEntries
                { cacheEntry?.remove() }
            }
        }
    }

/**
  A logical grouping of transformers and a cache.

  Why create separate stages?

  - To be able to append, replace, or remove some transformations independently of others, e.g. override the model
    transform without disabling JSON parsing.
  - To cache entities at any intermediate stage of processing.
  - To maintain multiple caches.

  - See: `Pipeline`
*/
public struct PipelineStage
    {
    private var transformers: [ResponseTransformer] = []
    private var cacheBox: CacheBox?

    /**
      Appends the given transformer to this stage.
    */
    public mutating func add(transformer: ResponseTransformer)
        { transformers.append(transformer) }

    /**
      Appends the given transformer to this stage, applying it only if the server’s `Content-type` header matches any of
      the `contentTypes`. The content type matching applies regardles of whether the response is a success or failure.

      Content type patterns can use * to match subsequences. The wildcard does not cross `/` or `+` boundaries. Examples:

          "text/plain"
          "text/​*"
          "application/​*+json"

      The pattern does not match MIME parameters, so "text/plain" matches "text/plain; charset=utf-8".
    */
    public mutating func add(
            transformer: ResponseTransformer,
            contentTypes: [String])
        {
        add(ContentTypeMatchTransformer(
            transformer, contentTypes: contentTypes))
        }

    /**
      Removes all transformers configured for this pipeline stage. Use this to replace defaults or previously configured
      transformers for specific resources:

          configure("/thinger/​*.raw") {
            $0.config.pipeline[.parsing].removeTransformers()
          }
    */
    public mutating func removeTransformers()
        { transformers.removeAll() }

    private var isEmpty: Bool
        { return cacheBox == nil && transformers.isEmpty }

    internal func process(response: Response) -> Response
        {
        return transformers.reduce(response)
            { $1.process($0) }
        }

    /**
      An optional persistent cache for this stage.

      When processing a response, the cache will received an entities after the stage’s transformers have run.

      When inflating a new resource, Siesta will ask
    */
    public mutating func cacheUsing<T: EntityCache>(cache: T)
        { cacheBox = CacheBox(cache: cache) }

    public mutating func doNotCache()
        { cacheBox = nil}
    }

extension PipelineStage
    {
    /**
      Ways of modifying a stage’s transformers. Used by `Service.configureTransformer(...)`.
    */
    public enum MutationAction
        {
        /// Remove all existing transformers and add the new one.
        case replaceExisting

        /// Add the new transformer at the end of the existing ones.
        case appendToExisting
        }
    }

/**
  An unique identifier for a `PipelineStage` within a `Pipeline`. Transformers and stages have no intrinsic notion of
  identity or equality, so these keys are the only way to alter transformers after they’re configured.

  Stage keys are arbitrary, and have no intrinsic meaning. The descriptions of the default stages are for human
  comprehensibility, and Siesta does not enforce them in any way (e.g. it does not prevent you from configuring the
  `rawData` stage to output something other than `NSData`).

  Because this is not an enum, you can add custom stages:

      extension PipelineStageKey {
        static let
            munging   = PipelineStageKey(description: "munging"),
            twiddling = PipelineStageKey(description: "twiddling")
      }

      ...

      service.configure {
          $0.config.pipeline.order = [.rawData, .munging, .twiddling, .cleanup]
      }
*/
public final class PipelineStageKey: _OpenEnum, CustomStringConvertible
    {
    /// A human-readable name for this key. Does not affect uniqueness, or any other logical behavior.
    public let description: String

    /// Creates a custom pipeline stage.
    public init(description: String)
        { self.description = description }
    }

// MARK: Default Stages
public extension PipelineStageKey
    {
    /// Response data still unprocessed. The stage typically contains no transformers.
    public static let rawData = PipelineStageKey(description: "rawData")

    /// Any bytes-to-bytes processing, such as decryption or decompression, not already performed by the network lib.
    public static let decoding = PipelineStageKey(description: "decoding")

    /// Transformation of bytes to an ADT or other generic data structure, e.g. a string, dictionary, or image.
    public static let parsing = PipelineStageKey(description: "parsing")

    /// Transformation from an ADT to a domain-specific model.
    public static let model = PipelineStageKey(description: "model")

    /// Error handling, validation, or any other general mop-up.
    public static let cleanup = PipelineStageKey(description: "cleanup")
    }

// MARK: Type erasure dance

private struct CacheBox
    {
    let buildEntry: (Resource) -> (CacheEntryProtocol?)

    init?<T: EntityCache>(cache: T?)
        {
        guard let cache = cache else { return nil }
        buildEntry = { CacheEntry(cache: cache, resource: $0) }
        }
    }

private protocol CacheEntryProtocol
    {
    func read() -> Entity?
    func write(entity: Entity)
    func updateTimestamp(timestamp: NSTimeInterval)
    func remove()
    }

private struct CacheEntry<Cache, Key where Cache: EntityCache, Cache.Key == Key>: CacheEntryProtocol
    {
    let cache: Cache
    let key: Key

    init?(cache: Cache, resource: Resource)
        {
        dispatch_assert_main_queue()

        guard let key = cache.key(for: resource) else { return nil }

        self.cache = cache
        self.key = key
        }

    func read() -> Entity?
        { return cache.readEntity(forKey: key) }

    func write(entity: Entity)
        { return cache.writeEntity(entity, forKey: key) }

    func updateTimestamp(timestamp: NSTimeInterval)
        { cache.updateEntityTimestamp(timestamp, forKey: key) }

    func remove()
        { cache.removeEntity(forKey: key) }
    }
