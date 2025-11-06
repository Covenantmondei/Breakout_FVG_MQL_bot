#property library

void BuildPostData(const string text, uchar &buffer[])
{
   int len = StringToCharArray(text, buffer);
   if(len > 0)
      ArrayResize(buffer, len - 1);
}

bool Validate(string licenseKey) export
{
   long account_id = (long)AccountInfoInteger(ACCOUNT_LOGIN);
   string url   = "https://txxcrypt-license.onrender.com/ea/validate/";
   string post  = "license_key=" + licenseKey + "&account_id=" + (string)account_id;
   string replyHeaders;
   uchar  postData[];
   uchar  result[];

   BuildPostData(post, postData);

   int res = WebRequest("POST",
                        url,
                        "Content-Type: application/x-www-form-urlencoded\r\n",
                        10000,
                        postData,
                        result,
                        replyHeaders);

   if(res == -1)
   {
      Print("WebRequest failed: ", GetLastError());
      return(false);
   }

   string response = CharArrayToString(result);
   Print("Response: ", response);
   bool ok = (StringFind(response, "\"valid\":\"License is valid.\"") != -1);
   return ok;
}

// void UpdateConnection(string licenseKey) export
// {
//    string url   = "https://txxcrypt-license.onrender.com/license/activate/";
//    string post  = "license_key=" + licenseKey;
//    string replyHeaders;
//    uchar  postData[];
//    uchar  result[];

//    BuildPostData(post, postData);
//    WebRequest("POST",
//               url,
//               "Content-Type: application/x-www-form-urlencoded\r\n",
//               10000,
//               postData,
//               result,
//               replyHeaders);
// }

// void UpdateDisconnect(string licenseKey) export
// {
//    string url   = "https://txxcrypt-license.onrender.com/license/deactivate/";
//    string post  = "license_key=" + licenseKey;
//    string replyHeaders;
//    uchar  postData[];
//    uchar  result[];

//    BuildPostData(post, postData);
//    WebRequest("POST",
//               url,
//               "Content-Type: application/x-www-form-urlencoded\r\n",
//               10000,
//               postData,
//               result,
//               replyHeaders);
// }

// bool Validate(string licenseKey, string productCode) export
// {
//    return Validate(licenseKey);
// }

// void updateConnectionStatus(string licenseKey) export
// {
//    UpdateConnection(licenseKey);
// }

// void updateHardwareId(string licenseKey) export
// {
//    // Hardware ID handling not required server-side; placeholder keeps interface compatible.
// }

// void updateConnectionStatusConnected(string licenseKey) export
// {
//    UpdateConnection(licenseKey);
// }

// void updateConnectionStatusDisconnected(string licenseKey) export
// {
//    UpdateDisconnect(licenseKey);
// }
