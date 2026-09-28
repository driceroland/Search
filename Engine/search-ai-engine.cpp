// search-ai-engine: the model behind "On this Mac" in Search's AI add-on.
//
// A small program of its own, not part of Search: Search starts it when a
// page is to be summarized on this Mac, talks to it over its standard input
// and output, one JSON object per line, and lets it go when it has been idle
// a while. It runs in the App Sandbox with no network and no files of its
// own to read: the model comes as a file Search has already opened, and
// checked, on descriptor 3 (see AIEngine.swift). All it can do is turn text
// into more text.
//
// In:   {"id":1,"system":"…","messages":[{"role":"user","content":"…"},…],
//        "max_tokens":768,"temperature":0.2}
//       {"stop":1}                         (the request with that id ends)
// Out:  {"ready":true,"context":8192}      (once, when the model is loaded)
//       {"id":1,"piece":"…"}               (as the answer comes)
//       {"id":1,"done":true,"prompt_tokens":n,"tokens":m}
//       {"id":1,"error":"…"}   or   {"error":"…"} before ready
//
// The prompt is written here, in Qwen3's own form (ChatML), with its
// thinking turned off the way its template does it — an empty think block —
// because left to llama.cpp's defaults it silently turns on. What a page or a
// person wrote is tokenized as plain text, never as the model's own control
// tokens: a page containing "<|im_end|>" can't close its turn and speak as
// someone else.
//
// Built by engine.sh against llama.cpp at a pinned commit.

#include "llama.h"
#include "nlohmann/json.hpp"

#include <poll.h>
#include <unistd.h>

#include <cstdio>
#include <random>
#include <set>
#include <string>
#include <vector>

using json = nlohmann::json;

static void say(const json & message) {
    // Anything not valid UTF-8 is replaced rather than thrown on.
    std::string line = message.dump(-1, ' ', false, json::error_handler_t::replace);
    line.push_back('\n');
    fwrite(line.data(), 1, line.size(), stdout);
    fflush(stdout);
}

static void quiet(ggml_log_level, const char *, void *) {}

// Tokens for `text`: `control` for the template's own markers, plain for
// everything anyone else wrote.
static bool tokens(const llama_vocab * vocab, const std::string & text, bool control, std::vector<llama_token> & out) {
    if (text.empty()) return true;
    std::vector<llama_token> made(text.size() + 16);
    int n = llama_tokenize(vocab, text.c_str(), (int) text.size(), made.data(), (int) made.size(), false, control);
    if (n < 0) {
        made.resize(-n);
        n = llama_tokenize(vocab, text.c_str(), (int) text.size(), made.data(), (int) made.size(), false, control);
        if (n < 0) return false;
    }
    out.insert(out.end(), made.begin(), made.begin() + n);
    return true;
}

// How many bytes at the start of `bytes` are whole UTF-8 characters: a token
// can end in the middle of one, and the rest comes with the next.
static size_t whole(const std::string & bytes) {
    size_t i = bytes.size();
    size_t back = 0;
    while (i > 0 && back < 4) {
        unsigned char c = bytes[i - 1];
        if ((c & 0xC0) != 0x80) {
            size_t need = c < 0x80 ? 1 : (c >> 5) == 0x6 ? 2 : (c >> 4) == 0xE ? 3 : (c >> 3) == 0x1E ? 4 : 1;
            return back + 1 >= need ? bytes.size() : i - 1;
        }
        i--;
        back++;
    }
    return bytes.size();
}

// All input goes through here, unbuffered, so what arrives while an answer
// is being written is never lost behind a stream's buffer.
static bool fill(std::string & carry, bool wait) {
    if (!wait) {
        struct pollfd in = {STDIN_FILENO, POLLIN, 0};
        if (poll(&in, 1, 0) <= 0 || !(in.revents & (POLLIN | POLLHUP))) return true;
    }
    char buf[65536];
    ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
    if (n <= 0) return false;
    carry.append(buf, (size_t) n);
    return true;
}

static bool next_line(std::string & carry, std::string & line) {
    while (true) {
        size_t end = carry.find('\n');
        if (end != std::string::npos) {
            line = carry.substr(0, end);
            carry.erase(0, end + 1);
            return true;
        }
        if (!fill(carry, true)) return false;
    }
}

// Requests called off before they began: skipped when their turn comes.
static std::set<int> cancelled;

// A "stop" for `id` waiting on the input, looked at between tokens. A stop
// for a request still waiting is remembered; any other line — the next
// request — is kept for later.
static bool stopped(int id, std::string & carry) {
    if (!fill(carry, false)) return true;  // Search has gone: nobody to answer.
    std::string kept;
    bool stop = false;
    size_t start = 0, end;
    while ((end = carry.find('\n', start)) != std::string::npos) {
        std::string line = carry.substr(start, end - start);
        start = end + 1;
        json message = json::parse(line, nullptr, false);
        if (message.is_object() && message.contains("stop") && message["stop"].is_number_integer()) {
            const int which = message["stop"].get<int>();
            if (which == id) stop = true;
            else if (cancelled.size() < 1024) cancelled.insert(which);
            continue;
        }
        kept += line + "\n";
    }
    carry = kept + carry.substr(start);
    return stop;
}

int main(int argc, char ** argv) {
    int context = 8192;
    for (int i = 1; i + 1 < argc; i++) {
        if (std::string(argv[i]) == "--context") context = std::max(2048, std::min(32768, atoi(argv[i + 1])));
    }
    llama_log_set(quiet, nullptr);
    llama_backend_init();

    // The model, as Search opened it.
    llama_model_params model_params = llama_model_default_params();
#if defined(__x86_64__)
    model_params.n_gpu_layers = 0;
#endif
    llama_model * model = llama_model_load_from_file("/dev/fd/3", model_params);
    if (!model) {
        say({{"error", "The model couldn't be loaded."}});
        return 1;
    }
    const llama_vocab * vocab = llama_model_get_vocab(model);

    llama_context_params context_params = llama_context_default_params();
    context_params.n_ctx = (uint32_t) context;
    context_params.n_batch = 2048;
    context_params.n_ubatch = 512;
    context_params.no_perf = true;
    llama_context * ctx = llama_init_from_model(model, context_params);
    if (!ctx) {
        say({{"error", "There isn't enough memory for the model."}});
        return 1;
    }
    say({{"ready", true}, {"context", context}});

    std::random_device seeds;
    std::string carry;
    std::string line;
    while (true) {
        if (!next_line(carry, line)) break;
        json request = json::parse(line, nullptr, false);
        if (request.is_object() && request.contains("stop") && request["stop"].is_number_integer()) {
            if (cancelled.size() < 1024) cancelled.insert(request["stop"].get<int>());
            continue;
        }
        if (!request.is_object() || !request.contains("id") || !request["id"].is_number_integer()) continue;
        const int id = request["id"].get<int>();
        if (cancelled.erase(id)) {
            say({{"id", id}, {"done", true}, {"stopped", true}, {"prompt_tokens", 0}, {"tokens", 0}});
            continue;
        }
        if (!request.contains("messages") || !request["messages"].is_array()) {
            say({{"id", id}, {"error", "No messages."}});
            continue;
        }
        const int most = std::max(16, std::min(2048, request.value("max_tokens", 768)));
        const float temperature = std::max(0.0f, std::min(1.5f, request.value("temperature", 0.2f)));

        // The conversation, in Qwen3's form.
        std::vector<llama_token> prompt;
        bool fine = true;
        if (llama_vocab_get_add_bos(vocab)) prompt.push_back(llama_vocab_bos(vocab));
        auto turn = [&](const std::string & role, const std::string & text) {
            fine = fine && tokens(vocab, "<|im_start|>" + role + "\n", true, prompt)
                && tokens(vocab, text, false, prompt)
                && tokens(vocab, "<|im_end|>\n", true, prompt);
        };
        if (request.contains("system") && request["system"].is_string()) turn("system", request["system"].get<std::string>());
        for (const auto & message : request["messages"]) {
            if (!message.is_object() || !message.contains("content") || !message["content"].is_string()) continue;
            const std::string role = message.value("role", "user") == "assistant" ? "assistant" : "user";
            turn(role, message["content"].get<std::string>());
        }
        fine = fine && tokens(vocab, "<|im_start|>assistant\n<think>\n\n</think>\n\n", true, prompt);
        if (!fine) {
            say({{"id", id}, {"error", "The page couldn't be read into the model."}});
            continue;
        }
        if ((int) prompt.size() + most > context) {
            say({{"id", id}, {"error", "The page is too long for the model on this Mac."}});
            continue;
        }

        llama_memory_clear(llama_get_memory(ctx), true);
        llama_sampler * sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40));
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95f, 1));
        llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05f, 1));
        if (temperature > 0) {
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature));
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(seeds()));
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
        }

        // The prompt goes in by batches no larger than the context allows.
        bool failed = false;
        for (size_t at = 0; at < prompt.size(); at += (size_t) context_params.n_batch) {
            size_t count = std::min((size_t) context_params.n_batch, prompt.size() - at);
            if (llama_decode(ctx, llama_batch_get_one(prompt.data() + at, (int32_t) count))) { failed = true; break; }
        }
        int made = 0;
        std::string pending;
        bool halted = false;
        while (!failed && made < most) {
            llama_token next = llama_sampler_sample(sampler, ctx, -1);
            if (llama_vocab_is_eog(vocab, next)) break;
            char piece[256];
            int n = llama_token_to_piece(vocab, next, piece, sizeof(piece), 0, false);
            if (n > 0) pending.append(piece, (size_t) n);
            size_t ready = whole(pending);
            if (ready > 0) {
                say({{"id", id}, {"piece", pending.substr(0, ready)}});
                pending.erase(0, ready);
            }
            made++;
            if (stopped(id, carry)) { halted = true; break; }
            if (llama_decode(ctx, llama_batch_get_one(&next, 1))) { failed = true; break; }
        }
        llama_sampler_free(sampler);
        if (failed) {
            say({{"id", id}, {"error", "The model stopped partway."}});
        } else {
            say({{"id", id}, {"done", true}, {"stopped", halted}, {"prompt_tokens", (int) prompt.size()}, {"tokens", made}});
        }
    }

    llama_free(ctx);
    llama_model_free(model);
    llama_backend_free();
    return 0;
}
