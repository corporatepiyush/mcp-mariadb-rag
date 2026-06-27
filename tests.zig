//! Test aggregator at project root. All tests live under tests/; src holds
//! production code only. This file is the root_source_file for the test build.

comptime {
    _ = @import("tests/actions_kg_test.zig");
    _ = @import("tests/actions_mod_test.zig");
    _ = @import("tests/actions_rag_test.zig");
    _ = @import("tests/actions_test.zig");
    _ = @import("tests/config_test.zig");
    _ = @import("tests/doc_csv_test.zig");
    _ = @import("tests/doc_detect_test.zig");
    _ = @import("tests/doc_doc_test.zig");
    _ = @import("tests/doc_docx_test.zig");
    _ = @import("tests/doc_iceberg_test.zig");
    _ = @import("tests/doc_inflate_test.zig");
    _ = @import("tests/doc_json_test.zig");
    _ = @import("tests/doc_mod_test.zig");
    _ = @import("tests/doc_parquet_test.zig");
    _ = @import("tests/doc_pdf_test.zig");
    _ = @import("tests/doc_pool_test.zig");
    _ = @import("tests/doc_text_test.zig");
    _ = @import("tests/doc_xml_test.zig");
    _ = @import("tests/doc_zip_test.zig");
    _ = @import("tests/e2e_test.zig");
    _ = @import("tests/embed_quant_test.zig");
    _ = @import("tests/generate_cache_test.zig");
    _ = @import("tests/index_flat_test.zig");
    _ = @import("tests/index_hnsw_test.zig");
    _ = @import("tests/index_store_test.zig");
    _ = @import("tests/integration_test.zig");
    _ = @import("tests/json_inline_test.zig");
    _ = @import("tests/json_test.zig");
    _ = @import("tests/kg_bench.zig");
    _ = @import("tests/kg_graph_test.zig");
    _ = @import("tests/kg_schema_test.zig");
    _ = @import("tests/kg_test.zig");
    _ = @import("tests/kg_types_test.zig");
    _ = @import("tests/kg_vector_test.zig");
    _ = @import("tests/observe_trace_test.zig");
    _ = @import("tests/pool_test.zig");
    _ = @import("tests/rag_bench.zig");
    _ = @import("tests/rag_chunk_test.zig");
    _ = @import("tests/rag_fusion_test.zig");
    _ = @import("tests/rag_query_test.zig");
    _ = @import("tests/rag_retrieve_test.zig");
    _ = @import("tests/rag_schema_test.zig");
    _ = @import("tests/rag_test.zig");
    _ = @import("tests/server_test.zig");
    _ = @import("tests/sqlite_test.zig");
    _ = @import("tests/transport_test.zig");
    _ = @import("tests/url_test.zig");
    _ = @import("tests/validation_inline_test.zig");
    _ = @import("tests/validation_test.zig");
}
