local BANK_CODE = "EBS"

WebBanking{version     = 1.01,
           url         = "https://onlinebanking.ebs.ie/EBSOnlineBankingWeb/onlinebanking",
           services    = {BANK_CODE},
           description = string.format(MM.localizeText("Get balance and transactions for %s"), BANK_CODE)}

function SupportsBank (protocol, bankCode)
    return protocol == ProtocolWebBanking and bankCode == BANK_CODE
end

local connection = Connection()
local loginUrl = "https://onlinebanking.ebs.ie/EBS/Services/Security/Login"
local loginStatusUrl = "https://onlinebanking.ebs.ie/EBS/Services/Security/GetMFALoginStatus"
local accountsUrl = "https://onlinebanking.ebs.ie/EBS/Services/EOTPMisc"
local logoutUrl = "https://onlinebanking.ebs.ie/EBS/Services/Security/Logout"
local authPingUrl = nil
local authPingCsrf = nil

function InitializeSession2 (protocol, bankCode, step, credentials, interactive)

    if step == 1 then
        local username = credentials[1]
        local password = credentials[2]

        -- send username
        local usernameRequest = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:log="http://www.ebs.ie/LoginService/"><soapenv:Header/><soapenv:Body><log:loginRequest><in><ID>' .. username .. '</ID></in></log:loginRequest></soapenv:Body></soapenv:Envelope>'
        local usernameResponse = apiCall(loginUrl, usernameRequest)
        if usernameResponse:xpath("//faultcode"):text() ~= "L1001" then
            return usernameResponse:xpath("//faultstring"):text()
        end

        -- send PAC
        local sessionId = usernameResponse:xpath("//sessionid"):text()
        local pacString = ""        
        local pacDigits = usernameResponse:xpath("//pacdigitrequest")
        pacDigits:each(
            function (index, element)
                local pacIndex = tonumber(element:text())
                local pacDigit = string.sub(password, pacIndex, pacIndex)
                pacString = pacString .. "<PACDigit>" .. pacDigit .. "</PACDigit>"
            end
        )
        
        local pacRequest = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:soapenc="http://schemas.xmlsoap.org/soap/encoding/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><soapenv:Header><soapenv:EOTP_SOAP_HEADER>' .. sessionId .. '</soapenv:EOTP_SOAP_HEADER></soapenv:Header><soapenv:Body><ns8:loginRequest xmlns="" xmlns:ns6="http://www.ebs.ie/OnlineBanking/" xmlns:ns7="http://www.ebs.ie/EBSCustomerServices/" xmlns:ns8="http://www.ebs.ie/LoginService/"><in><ID></ID>' .. pacString .. '<SecurityAnswer></SecurityAnswer><Role>OB.Adult</Role></in></ns8:loginRequest></soapenv:Body></soapenv:Envelope>'
        local pacResponse = apiCall(loginUrl, pacRequest)

        if pacResponse:xpath("//faultcode"):text() ~= "L1024" then
            return pacResponse:xpath("//faultstring"):text()
        end
        
        -- request 2FA
        local redirectURI = pacResponse:xpath("//redirecturi"):text()
        local authorisationResponse = HTML(connection:request("GET", redirectURI))
        authPingUrl = "https://auth.ebs.ie" .. authorisationResponse:xpath('//form[@id="finalizeForm"]'):attr('action')
        authPingCsrf = authorisationResponse:xpath('//form[@id="finalizeForm"]/input[@name="csrfToken"]'):attr('value')
        
        return {challenge="Bitte bestätigen Sie die Daten in Ihrer Banking-App, um den Umsatzabruf zu erlauben."}
    
    end -- step 1

    if step == 2 then

        -- check login status
        local loginStatus = "Checking 2FA"
        local loginStatusChecks = 0
        while loginStatusChecks < 10 do
            -- send ping
            connection:request("POST", authPingUrl, "csrfToken=" .. authPingCsrf, "application/x-www-form-urlencoded; charset=UTF-8")
            -- check login status           
            local loginStatusRequest = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:axw="http://www.ebs.ie/AxwayService/"><soapenv:Header/><soapenv:Body><ns2:getMFAStatus xmlns:ns2="http://www.ebs.ie/AxwayService/"></ns2:getMFAStatus></soapenv:Body></soapenv:Envelope>'
            local loginStatusResponse = apiCall(loginStatusUrl, loginStatusRequest)
            loginStatus = loginStatusResponse:xpath("//status"):text()
            MM.printStatus(loginStatus)
            if loginStatus == "2-MFA Succeeded" then
                break
            end
            loginStatusChecks = loginStatusChecks + 1
            MM.sleep(3)
        end
        if loginStatus ~= "2-MFA Succeeded" then
            return "2FA failed"
        end
    
    end -- step 2

end

function ListAccounts (knownAccounts)
    local listAccountsRequest = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:onl="http://www.ebs.ie/OnlineBanking/"><soapenv:Header><TIMESTAMP>' .. getTimestampLong() .. '</TIMESTAMP></soapenv:Header><soapenv:Body><onl:retrieveAccountProfile><in><serviceVersion>1.0</serviceVersion></in></onl:retrieveAccountProfile></soapenv:Body></soapenv:Envelope>'
    local listAccountsResponse = apiCall(accountsUrl, listAccountsRequest)

    local accounts = {}
    local owner = listAccountsResponse:xpath("//customerinfo/name"):text()
    listAccountsResponse:xpath("//account"):each(
        function(index, account)
            table.insert(accounts, {
                name = account:xpath(".//displayname"):text(),
                owner = owner,
                accountNumber = account:xpath(".//accountnumber"):text(),
                currency = "EUR",
                iban = account:xpath(".//iban"):text(),
                bic = account:xpath(".//bic"):text(),
                type = AccountTypeGiro
            })
        end
    )

    return accounts
end

function RefreshAccount (account, since)
    local refreshAccountRequest = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:onl="http://www.ebs.ie/OnlineBanking/"><soapenv:Header><TIMESTAMP>' .. getTimestampLong() .. '</TIMESTAMP></soapenv:Header><soapenv:Body><onl:retrieveRecentTxnsForGraph><in><serviceVersion>1.0</serviceVersion><viewAccount><accountNumber>' .. account.accountNumber .. '</accountNumber></viewAccount><fromDate>' .. os.date("%Y-%m-%d", since) .. '</fromDate><toDate>' .. os.date("%Y-%m-%d") .. '</toDate><retrievePendingTransactions>true</retrievePendingTransactions></in></onl:retrieveRecentTxnsForGraph></soapenv:Body></soapenv:Envelope>'
    local refreshAccountResponse = apiCall(accountsUrl, refreshAccountRequest)

    local balance = nil
    local transactions = {}

    local bookingCodes = {
        ["DCR"] = "Direct Credits",
        ["INT"] = "Internet Payments",
        ["LDG"] = "Lodgements/Credits",
        ["OCR"] = "Other Credit",
        ["ATM"] = "ATM Transactions",
        ["CHG"] = "Charges/Fees",
        ["D/D"] = "Direct Debits",
        ["INT"] = "Internet Transactions",
        ["ODB"] = "Other Debits",
        ["POS"] = "Point of Sale",
        ["S/O"] = "Standing Orders",
        ["WCS"] = "Cash Withdrawals",
        ["WCQ"] = "Cheque Withdrawals"
    }

    refreshAccountResponse:xpath("//transaction"):each(
        function(index, transaction)
            if balance == nil then
                balance = transaction:xpath(".//balance"):text()
            end
            
            local purpose = nil
            if transaction:xpath(".//originalamount"):text() ~= "0.00" then
                purpose = transaction:xpath(".//originalamount"):text() .. " " .. transaction:xpath(".//originalcurrency"):text() .. ", Rate: " .. transaction:xpath(".//exchangerate"):text() .. ", FX fee: " .. transaction:xpath(".//foreigntxncharge"):text() 
            end
            
            local bookingCode = transaction:xpath(".//transactiontype"):text()
            local bookingText = nil
            if bookingCodes[bookingCode] then
                bookingText = bookingCodes[bookingCode]
            else
                bookingText = bookingCode
            end
            
            table.insert(transactions, {
                name = transaction:xpath(".//description"):text(),
                amount = transaction:xpath(".//txnamount"):text(),
                bookingDate = dateToTimestamp(transaction:xpath(".//dateposted"):text()),
                purpose = purpose,
                bookingText = bookingText,
                booked = true
            })
        end
    )
    
    refreshAccountResponse:xpath("//pendingtransaction"):each(
        function(index, transaction)
            local bookingCode = transaction:xpath(".//transactiontype"):text()
            local bookingText = nil
            if bookingCodes[bookingCode] then
                bookingText = bookingCodes[bookingCode]
            else
                bookingText = bookingCode
            end
            
            table.insert(transactions, {
                name = transaction:xpath(".//transactiondesc"):text(),
                amount = transaction:xpath(".//transactionamount"):text(),
                bookingDate = dateToTimestamp(transaction:xpath(".//transactiondate"):text()),
                bookingText = bookingText,
                booked = false
            })
        end
    )
    
    return {balance = balance, transactions = transactions}
end

function EndSession ()
    local logoutRequest = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:log="http://www.ebs.ie/LoginService/"><soapenv:Header><TIMESTAMP>' .. getTimestampLong() .. '</TIMESTAMP></soapenv:Header><soapenv:Body><log:logoutRequest/></soapenv:Body></soapenv:Envelope>'
    apiCall(logoutUrl, logoutRequest)
end


-- helper functions

function apiCall (url, data)
    local headers = {}
    headers["Accept"] = "application/xml"
    content = connection:request("POST", url, data, "text/xml", headers)
    return HTML(content)
end

function getTimestampLong()
    return os.time() * 1000, ".0000"
end

function dateToTimestamp(dateStr)
    local day, month, year = string.match(dateStr, "(%d%d)/(%d%d)/(%d%d%d%d)")
    return os.time({year=year, month=month, day=day})
end
