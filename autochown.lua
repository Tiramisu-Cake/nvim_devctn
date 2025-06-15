local M = {}
do
    local uid = os.getenv("HOST_UID")
    local gid_raw = os.getenv("HOST_GID")
    -- если gid пустой или nil — оставляем nil, иначе юзаем
    local gid = (gid_raw and #gid_raw > 0) and gid_raw or nil
    if not uid then
        print("!! HOST_UID не задан, авточон не встанет")
        return
    end

    vim.api.nvim_create_autocmd("BufWritePost", {
        pattern = "*",
        callback = function()
            local file = vim.fn.expand("%:p")
            local spec = gid and (uid .. ":" .. gid) or uid
            -- вот тут синхронно, чтоб точно видеть ошибку
            local out = vim.fn.system("chown " .. spec .. " " .. file .. " 2>&1")
        end,
    })
end
return M
