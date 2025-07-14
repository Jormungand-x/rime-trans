-- ============================================================
-- 云翻译模块 for Rime 输入法引擎
-- 功能：提供多种云翻译服务，通过特定触发键显示翻译结果
-- 支持翻译服务：小牛翻译、Google翻译、DeepL、Microsoft翻译、有道翻译、百度翻译
-- ============================================================

-- 引入必要的库
local json = require("cloud_json")  -- JSON解析库
local sha2 = require("cloud_sha2")  -- 加密库，用于有道和百度翻译的签名生成

-- ============================================================
-- 环境初始化部分
-- ============================================================

-- 获取当前 Lua 文件的路径（兼容PC和安卓的初始化代码）
local http = nil  -- HTTP模块占位符
local luaDir = "" -- 当前Lua文件所在目录

-- 环境检测函数：判断是否在Android系统上运行
local function is_android()
    -- 检测安卓特有的环境变量或文件系统结构
    if package.config:sub(1,1) == "/" then  -- 目录分隔符是斜杠（Unix-like系统）
        if os.getenv("ANDROID_ROOT") then  -- 检查安卓环境变量
            return true
        end
        -- 检查是否存在安卓特有文件
        local f = io.open("/system/build.prop", "r")
        if f then
            f:close()
            return true
        end
    end
    return false
end

-- 仅PC环境需要文件路径操作
if not is_android() then
    -- 获取当前 Lua 文件的路径 (仅PC环境)
    local function getCurrentLuaFilePath()
        local info = debug.getinfo(2, "S")
        if info and info.source then
            local source = info.source
            if source:sub(1, 1) == "@" then
                local fullPath = source:sub(2)
                -- 找到路径中最后一个斜杠或反斜杠的位置
                local lastSlashIndex = fullPath:match(".*()[/\\]")
                if lastSlashIndex then
                    return fullPath:sub(1, lastSlashIndex)
                end
            end
        end
        log.error("Failed to get current Lua file path.")
        return ""
    end
    
    -- 获取当前 Lua 文件所在的目录路径
    luaDir = getCurrentLuaFilePath() or ""
    
    -- 设置C模块路径 (仅PC环境)
    pcall(function()
        -- 添加DLL和SO文件的搜索路径
        package.cpath = package.cpath .. ";" .. luaDir .. "?.dll"
        package.cpath = package.cpath .. ";" .. luaDir .. "?.so"
    end)
end

-- 安全加载HTTP模块
local has_http, http_mod = pcall(require, "simplehttp")
if has_http and http_mod then
    http = http_mod
    http.TIMEOUT = 0.5  -- 设置HTTP请求超时时间
    log.info("HTTP模块加载成功")
else
    -- 创建模拟HTTP模块 (用于安卓或加载失败的情况)
    http = {
        request = function(params)
            log.warning("HTTP模块不可用: 模拟请求")
            return nil
        end
    }
    log.warning("HTTP模块加载失败，使用模拟实现")
end

-- ============================================================
-- 配置系统
-- ============================================================

-- 默认配置
local default_config = {
    default_api = "niutrans",  -- 默认使用的翻译API
    api_keys = {
        niutrans = { api_key = "YOUR_NIUTRANS_API_KEY" },  -- 小牛翻译API密钥
        deepl = "YOUR_DEEPL_API_KEY",  -- DeepL API密钥
        microsoft = {
            key = "YOUR_MS_TRANSLATOR_API_KEY",  -- Microsoft翻译API密钥
            region = "global"  -- Microsoft API区域
        },
        youdao = {
            app_id = "YOUR_YOUDAO_APP_ID",  -- 有道翻译应用ID
            app_key = "YOUR_YOUDAO_APP_KEY"  -- 有道翻译应用密钥
        },
        baidu = {
            app_id = "YOUR_BAIDU_APP_ID",  -- 百度翻译应用ID
            app_key = "YOUR_BAIDU_APP_KEY"  -- 百度翻译应用密钥
        }
    },
    trigger_key = "''",  -- 触发翻译的按键（默认是两个单引号）
    target_lang0 = "en",  -- 默认目标语言1
    target_lang1 = "ja"   -- 默认目标语言2（用于日语选项）
}

-- 支持的语言列表
local SUPPORTED_LANGUAGES = {
    en = "English", zh = "Chinese", ja = "Japanese", ko = "Korean", 
    ru = "Russian", fr = "French", es = "Spanish", pt = "Portuguese", 
    ar = "Arabic", th = "Thai", cht = "Traditional Chinese", vi = "Vietnamese",
    id = "Indonesian", de = "German", it = "Italian", jp = "Japanese"
}

-- 语言简称（用于结果显示）
local LANGUAGE_SHORT_NAME = {
    en = "英", zh = "中", ja = "日", ko = "韩", ru = "俄", 
    fr = "法", es = "西", pt = "葡", ar = "阿", th = "泰", 
    vi = "越", id = "印", de = "德", it = "意", cht = "繁"
}

-- Google翻译语言映射（将通用语言代码映射到Google特定代码）
local GOOGLE_LANG_MAP = {
    en = "en", zh = "zh-CN", ja = "ja", ko = "ko", ru = "ru", 
    fr = "fr", es = "es", pt = "pt", ar = "ar", th = "th", 
    vi = "vi", id = "id", de = "de", it = "it", cht = "zh-TW",
    jp = "ja"
}

-- DeepL翻译语言映射（将通用语言代码映射到DeepL特定代码）
local DEEPL_LANG_MAP = {
    en = "EN", zh = "ZH", ja = "JA", ko = "KO", ru = "RU", 
    fr = "FR", es = "ES", pt = "PT", it = "IT", de = "DE",
    cht = "ZH"
}

-- Microsoft翻译语言映射（将通用语言代码映射到Microsoft特定代码）
local MICROSOFT_LANG_MAP = {
    en = "en", zh = "zh-Hans", ja = "ja", ko = "ko", ru = "ru", 
    fr = "fr", es = "es", pt = "pt", ar = "ar", th = "th", 
    vi = "vi", id = "id", de = "de", it = "it", cht = "zh-Hant",
    jp = "ja"
}

-- URL编码函数：将字符串转换为URL安全格式
local function url_encode(str)
    if not str then return "" end
    -- 替换所有非字母数字字符为%XX格式
    str = string.gsub(str, "([^%w %-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    -- 将空格替换为+
    return string.gsub(str, " ", "+")
end

-- 获取配置函数：从Rime配置文件中读取用户设置
local function get_config(env)
    -- 创建配置表，初始化为默认值
    local config = {
        default_api = default_config.default_api,
        api_keys = {
            niutrans = { api_key = default_config.api_keys.niutrans.api_key },
            deepl = default_config.api_keys.deepl,
            microsoft = {
                key = default_config.api_keys.microsoft.key,
                region = default_config.api_keys.microsoft.region
            },
            youdao = {
                app_id = default_config.api_keys.youdao.app_id,
                app_key = default_config.api_keys.youdao.app_key
            },
            baidu = {
                app_id = default_config.api_keys.baidu.app_id,
                app_key = default_config.api_keys.baidu.app_key
            }
        },
        trigger_key = default_config.trigger_key,
        target_lang0 = default_config.target_lang0,
        target_lang1 = default_config.target_lang1
    }
    
    -- 如果没有引擎环境，直接返回默认配置
    if not env.engine then return config end
    local schema_config = env.engine.schema.config
    if not schema_config then return config end
    
    -- 从Rime配置文件中读取用户设置，覆盖默认值
    config.default_api = schema_config:get_string("cloud_translation/default_api") or config.default_api
    config.api_keys.niutrans.api_key = schema_config:get_string("cloud_translation/api_keys/niutrans/api_key") or config.api_keys.niutrans.api_key
    config.api_keys.deepl = schema_config:get_string("cloud_translation/api_keys/deepl") or config.api_keys.deepl
    config.api_keys.microsoft.key = schema_config:get_string("cloud_translation/api_keys/microsoft/key") or config.api_keys.microsoft.key
    config.api_keys.microsoft.region = schema_config:get_string("cloud_translation/api_keys/microsoft/region") or config.api_keys.microsoft.region
    config.api_keys.youdao.app_id = schema_config:get_string("cloud_translation/api_keys/youdao/app_id") or config.api_keys.youdao.app_id
    config.api_keys.youdao.app_key = schema_config:get_string("cloud_translation/api_keys/youdao/app_key") or config.api_keys.youdao.app_key
    config.api_keys.baidu.app_id = schema_config:get_string("cloud_translation/api_keys/baidu/app_id") or config.api_keys.baidu.app_id
    config.api_keys.baidu.app_key = schema_config:get_string("cloud_translation/api_keys/baidu/app_key") or config.api_keys.baidu.app_key
    config.trigger_key = schema_config:get_string("cloud_translation/trigger_key") or config.trigger_key
    config.target_lang0 = schema_config:get_string("cloud_translation/target_lang0") or config.target_lang0
    config.target_lang1 = schema_config:get_string("cloud_translation/target_lang1") or config.target_lang1
    
    -- 根据选项设置目标语言（如果启用了日语选项则使用target_lang1）
    config.target_lang = env.engine.context:get_option("cloud_translation_japanese") 
                         and config.target_lang1 or config.target_lang0
    
    return config
end

-- ============================================================
-- 翻译API实现部分
-- ============================================================

-- 小牛翻译API
local function niutrans(text, config)
    local api_key = config.api_keys.niutrans.api_key
    local target_lang = config.target_lang:lower()  -- 转换为小写
    
    -- API密钥检查
    if not api_key or api_key == "" or api_key == "YOUR_NIUTRANS_API_KEY" then
        return nil, "API密钥未配置"
    end
    
    -- 语言支持检查
    if not SUPPORTED_LANGUAGES[target_lang] then
        return nil, "不支持的目标语言: " .. target_lang
    end
    
    -- 特殊语言代码处理（jp映射到ja）
    if target_lang == "jp" then target_lang = "ja" end
    
    -- 构建请求
    local url = "https://api.niutrans.com/NiuTransServer/translation"
    local request_body = json.encode({
        from = "auto",  -- 自动检测源语言
        to = target_lang,  -- 目标语言
        apikey = api_key,  -- API密钥
        src_text = text  -- 要翻译的文本
    })
    
    -- 发送POST请求
    local reply = http.request{
        url = url,
        method = "POST",
        headers = {["Content-Type"] = "application/json"},
        data = request_body
    }
    
    -- 检查响应是否为空
    if not reply or reply == "" then
        return nil, "API请求失败"
    end
    
    -- 解析JSON响应
    local success, j = pcall(json.decode, reply)
    if not success then
        return nil, "API响应解析失败"
    end
    
    -- 错误处理
    if j.error_code then
        local error_msg = "API错误 " .. j.error_code
        if j.error_msg then error_msg = error_msg .. ": " .. j.error_msg end
        return nil, error_msg
    end
    
    -- 提取翻译结果
    if j.tgt_text then
        if type(j.tgt_text) == "string" then
            return j.tgt_text
        elseif type(j.tgt_text) == "table" and j.tgt_text.content then
            return j.tgt_text.content
        end
    end
    
    return nil, "未找到翻译结果"
end

-- Google翻译API
local function google_translate(text, config)
    local target_lang = config.target_lang:lower()
    -- 获取Google特定的语言代码，默认为英语
    local google_lang = GOOGLE_LANG_MAP[target_lang] or "en"
    
    -- 构建请求URL
    local url = "https://translate.googleapis.com/translate_a/single?" ..
                "client=gtx&sl=auto&tl=" .. google_lang .. "&dt=t&q=" .. 
                url_encode(text)
    
    -- 发送GET请求
    local reply = http.request(url)
    if not reply or reply == "" then
        return nil, "API请求失败"
    end
    
    -- 尝试解析JSON响应
    local success, j = pcall(json.decode, reply)
    if success and j and j.sentences and j.sentences[1] then
        return j.sentences[1].trans
    end
    
    -- 如果JSON解析失败，尝试原始字符串匹配
    local translated = reply:match('"trans":"([^"]+)"') or 
                      reply:match('%[%[%["([^"]+)"')
    if translated then
        return translated
    end
    
    return nil, "未找到翻译结果"
end

-- DeepL翻译API
local function deepl_translate(text, config)
    local api_key = config.api_keys.deepl
    local target_lang = config.target_lang:lower()
    
    -- API密钥检查
    if not api_key or api_key == "" or api_key == "YOUR_DEEPL_API_KEY" then
        return nil, "DeepL API密钥未配置"
    end
    
    -- 语言支持检查
    if not DEEPL_LANG_MAP[target_lang] then
        return nil, "DeepL不支持的目标语言: " .. target_lang
    end
    
    -- 特殊语言代码处理（jp映射到ja）
    if target_lang == "jp" then target_lang = "ja" end
    
    -- 获取DeepL特定的语言代码，默认为英语
    local deepl_lang = DEEPL_LANG_MAP[target_lang] or "EN"
    
    -- 构建请求
    local url = "https://api-free.deepl.com/v2/translate"
    local body = "auth_key=" .. api_key .. 
                 "&text=" .. url_encode(text) .. 
                 "&target_lang=" .. deepl_lang
    
    -- 发送POST请求
    local reply = http.request{
        url = url,
        method = "POST",
        headers = {["Content-Type"] = "application/x-www-form-urlencoded"},
        data = body
    }
    
    if not reply or reply == "" then
        return nil, "DeepL API请求失败"
    end
    
    -- 解析JSON响应
    local success, j = pcall(json.decode, reply)
    if not success then
        return nil, "DeepL API响应解析失败"
    end
    
    -- 错误处理
    if j.message then
        return nil, "DeepL错误: " .. j.message
    end
    
    -- 提取翻译结果
    if j.translations and j.translations[1] and j.translations[1].text then
        return j.translations[1].text
    end
    
    return nil, "DeepL未找到翻译结果"
end

-- Microsoft翻译API
local function microsoft_translate(text, config)
    local api_key = config.api_keys.microsoft.key
    local region = config.api_keys.microsoft.region
    local target_lang = config.target_lang:lower()
    
    -- API密钥检查
    if not api_key or api_key == "" or api_key == "YOUR_MS_TRANSLATOR_API_KEY" then
        return nil, "Microsoft API密钥未配置"
    end
    
    -- 语言支持检查
    if not MICROSOFT_LANG_MAP[target_lang] then
        return nil, "Microsoft不支持的目标语言: " .. target_lang
    end
    
    -- 特殊语言代码处理（jp映射到ja）
    if target_lang == "jp" then target_lang = "ja" end
    
    -- 获取Microsoft特定的语言代码，默认为英语
    local ms_lang = MICROSOFT_LANG_MAP[target_lang] or "en"
    
    -- 构建请求
    local url = "https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&to=" .. ms_lang
    -- 构建请求体（JSON格式）
    local request_body = json.encode({{Text = text}})
    
    -- 发送POST请求
    local reply = http.request{
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Ocp-Apim-Subscription-Key"] = api_key,
            ["Ocp-Apim-Subscription-Region"] = region
        },
        data = request_body
    }
    
    if not reply or reply == "" then
        return nil, "Microsoft API请求失败"
    end
    
    -- 解析JSON响应
    local success, j = pcall(json.decode, reply)
    if not success then
        return nil, "Microsoft API响应解析失败"
    end
    
    -- 错误处理
    if j.error then
        return nil, "Microsoft错误: " .. (j.error.message or "未知错误")
    end
    
    -- 提取翻译结果
    if j[1] and j[1].translations and j[1].translations[1] and j[1].translations[1].text then
        return j[1].translations[1].text
    end
    
    return nil, "Microsoft未找到翻译结果"
end

-- 有道翻译API（特别注意UTF-8编码处理）
local function youdao_translate(text, config)
    local app_id = config.api_keys.youdao.app_id
    local app_key = config.api_keys.youdao.app_key
    local target_lang = config.target_lang:lower()
    
    -- API密钥检查
    if not app_id or app_id == "" or app_id == "YOUR_YOUDAO_APP_ID" or
       not app_key or app_key == "" or app_key == "YOUR_YOUDAO_APP_KEY" then
        return nil, "有道API密钥未配置"
    end
    
    -- 语言支持检查
    if not SUPPORTED_LANGUAGES[target_lang] then
        return nil, "有道不支持的目标语言: " .. target_lang
    end
    
    -- 特殊语言代码处理（jp映射到ja）
    if target_lang == "jp" then target_lang = "ja" end
    
    -- 生成签名所需参数
    local salt = tostring(math.random(32768, 65536))  -- 随机盐值
    local curtime = tostring(os.time())  -- 当前时间戳
    
    -- 处理输入文本（特别注意UTF-8编码）
    local function get_input(q)
        -- 确保文本是UTF-8编码
        local utf8_text = q
        
        -- 如果支持utf8库，使用更安全的字符处理
        if utf8.len then
            -- 计算UTF-8字符串的实际长度
            local len = utf8.len(utf8_text) or #utf8_text
            if len <= 20 then
                return utf8_text
            end
            
            -- 安全截取前10个字符（避免截断多字节字符）
            local first10 = utf8_text:sub(1, utf8.offset(utf8_text, 11) - 1)
            -- 安全截取后10个字符
            local last10 = utf8_text:sub(utf8.offset(utf8_text, -9))
            return first10 .. tostring(len) .. last10
        else
            -- 没有utf8库时的备选方案
            if #utf8_text <= 20 then
                return utf8_text
            end
            return utf8_text:sub(1,10) .. tostring(#utf8_text) .. utf8_text:sub(-10)
        end
    end
    
    -- 获取处理后的输入
    local input = get_input(text)
    -- 生成签名字符串
    local sign_str = app_id .. input .. salt .. curtime .. app_key
    -- 计算SHA256签名
    local sign = sha2.sha256(sign_str)
    
    -- 构建请求
    local url = "https://openapi.youdao.com/api"
    local body = "q=" .. url_encode(text) ..
                 "&from=auto" ..  -- 自动检测源语言
                 "&to=" .. target_lang ..  -- 目标语言
                 "&appKey=" .. app_id ..  -- 应用ID
                 "&salt=" .. salt ..  -- 随机盐值
                 "&sign=" .. sign ..  -- 签名
                 "&signType=v3" ..  -- 签名类型
                 "&curtime=" .. curtime  -- 当前时间戳
    
    -- 发送POST请求
    local reply = http.request{
        url = url,
        method = "POST",
        headers = {["Content-Type"] = "application/x-www-form-urlencoded"},
        data = body
    }
    
    if not reply or reply == "" then
        return nil, "有道API请求失败"
    end
    
    -- 解析JSON响应
    local success, j = pcall(json.decode, reply)
    if not success then
        return nil, "有道API响应解析失败"
    end
    
    -- 错误处理
    if j.errorCode and j.errorCode ~= "0" then
        return nil, "有道错误 " .. j.errorCode .. ": " .. (j.message or "未知错误")
    end
    
    -- 提取翻译结果
    if j.translation and j.translation[1] then
        return j.translation[1]
    end
    
    return nil, "有道未找到翻译结果"
end

-- 百度翻译API
local function baidu_translate(text, config)
    local app_id = config.api_keys.baidu.app_id
    local app_key = config.api_keys.baidu.app_key
    local target_lang = config.target_lang:lower()
    
    -- API密钥检查
    if not app_id or app_id == "" or app_id == "YOUR_BAIDU_APP_ID" or
       not app_key or app_key == "" or app_key == "YOUR_BAIDU_APP_KEY" then
        return nil, "百度API密钥未配置"
    end
    
    -- 语言支持检查
    if not SUPPORTED_LANGUAGES[target_lang] then
        return nil, "百度不支持的目标语言: " .. target_lang
    end
    
    -- 特殊语言代码处理（jp映射到ja）
    if target_lang == "jp" then target_lang = "ja" end
    
    -- 生成签名
    local salt = tostring(math.random(32768, 65536))  -- 随机盐值
    -- 计算MD5签名（app_id+text+salt+app_key）
    local sign = sha2.md5(app_id .. text .. salt .. app_key):lower()
    
    -- 构建请求
    local url = "https://fanyi-api.baidu.com/api/trans/vip/translate"
    local body = "q=" .. url_encode(text) ..
                 "&from=auto" ..  -- 自动检测源语言
                 "&to=" .. target_lang ..  -- 目标语言
                 "&appid=" .. app_id ..  -- 应用ID
                 "&salt=" .. salt ..  -- 随机盐值
                 "&sign=" .. sign  -- 签名
    
    -- 发送POST请求
    local reply = http.request{
        url = url,
        method = "POST",
        headers = {["Content-Type"] = "application/x-www-form-urlencoded"},
        data = body
    }
    
    if not reply or reply == "" then
        return nil, "百度API请求失败"
    end
    
    -- 解析JSON响应
    local success, j = pcall(json.decode, reply)
    if not success then
        return nil, "百度API响应解析失败"
    end
    
    -- 错误处理
    if j.error_code then
        return nil, "百度错误 " .. j.error_code .. ": " .. (j.error_msg or "未知错误")
    end
    
    -- 提取翻译结果
    if j.trans_result and j.trans_result[1] and j.trans_result[1].dst then
        return j.trans_result[1].dst
    end
    
    return nil, "百度未找到翻译结果"
end

-- ============================================================
-- 辅助函数
-- ============================================================

-- 检查字符是否为中文字符
local function is_chinese_character(char)
    local code = utf8.codepoint(char)
    -- 检查Unicode编码是否在汉字范围内
    return code >= 0x4E00 and code <= 0x9FFF
end

-- ============================================================
-- 主过滤器函数
-- ============================================================

-- Rime过滤器入口函数
local function filter(input, env)
    local context = env.engine.context
    local input_text = context.input  -- 获取当前输入文本
    local config = get_config(env)  -- 获取配置
    local trigger_key = config.trigger_key  -- 触发键
    local trigger_length = #trigger_key  -- 触发键长度
    
    -- 检查输入文本是否以触发键结尾
    if trigger_length > 0 and input_text:sub(-trigger_length) == trigger_key then
        -- 创建一个临时表存储原始候选词
        local candidates = {}
        
        -- 首先收集所有原始候选词
        for cand in input:iter() do
            table.insert(candidates, cand)
        end
        
        -- 如果没有候选词，显示错误信息
        if #candidates == 0 then
            yield(Candidate("error", 0, #input_text, "[无候选词]", "请检查输入"))
            return
        end
        
        -- 获取第一个候选词
        local first_cand = candidates[1]
        local cand_text = first_cand.text
        
        -- 检查候选词是否有效
        if not cand_text or #cand_text == 0 then
            yield(Candidate("error", 0, #input_text, "[空候选词]", "请检查输入"))
            -- 输出其他候选词
            for i = 1, #candidates do
                yield(candidates[i])
            end
            return
        end
        
        -- 检查第一个字符是否是中文
        local first_char = utf8.char(utf8.codepoint(cand_text, 1))
        if not is_chinese_character(first_char) then
            yield(Candidate("error", 0, #input_text, "[非中文候选词]", "请检查输入"))
            -- 输出其他候选词
            for i = 1, #candidates do
                yield(candidates[i])
            end
            return
        end
        
        -- 调用翻译API（根据配置选择不同的翻译服务）
        local translated_text, error_msg
        if config.default_api == "google" then
            translated_text, error_msg = google_translate(cand_text, config)
        elseif config.default_api == "deepl" then
            translated_text, error_msg = deepl_translate(cand_text, config)
        elseif config.default_api == "microsoft" then
            translated_text, error_msg = microsoft_translate(cand_text, config)
        elseif config.default_api == "youdao" then
            translated_text, error_msg = youdao_translate(cand_text, config)
        elseif config.default_api == "baidu" then
            translated_text, error_msg = baidu_translate(cand_text, config)
        else
            -- 默认使用小牛翻译
            translated_text, error_msg = niutrans(cand_text, config)
        end
        
        -- 处理翻译结果
        if translated_text then
            -- 获取目标语言的简称
            local lang_display = LANGUAGE_SHORT_NAME[config.target_lang] or 
                                LANGUAGE_SHORT_NAME[config.target_lang:lower()] or 
                                config.target_lang
            
            -- 输出翻译结果作为第一个候选词
            yield(Candidate("translation", 0, #input_text, 
                           translated_text, 
                           "["..lang_display.."译] " .. cand_text))
            
            -- 输出所有原始候选词（包括第一个）
            for i = 1, #candidates do
                yield(candidates[i])
            end
        else
            -- 输出错误信息作为第一个候选词
            yield(Candidate("error", 0, #input_text, 
                           "[翻译失败] " .. (error_msg or ""), "翻译错误"))
            
            -- 输出所有原始候选词
            for i = 1, #candidates do
                yield(candidates[i])
            end
        end
    else
        -- 非触发状态，直接输出所有候选词
        for cand in input:iter() do
            yield(cand)
        end
    end
end

-- 返回过滤器函数
return filter