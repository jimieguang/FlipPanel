using System.Globalization;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;

namespace ReuseDisplay.Agent.Netease;

/// <summary>
/// 网易云 weapi 加密：AES-128-CBC 二次加密 + RSA 公钥加密随机密钥。
/// 参考 netease-api-analysis/src/client.js 的 buildWeapiPayload 实现。
/// </summary>
internal static class Weapi
{
    private static readonly byte[] PresetKey = Encoding.UTF8.GetBytes("0CoJUm6Qyw8W8jud");
    private static readonly byte[] IV = Encoding.UTF8.GetBytes("0102030405060708");
    private const string PubKeyHex = "010001";
    private const string ModulusHex =
        "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725" +
        "152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312" +
        "ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424" +
        "d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7";

    private static readonly BigInteger Exponent = ParsePositiveHex(PubKeyHex);
    private static readonly BigInteger Modulus = ParsePositiveHex(ModulusHex);

    private static readonly char[] RandomChars =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".ToCharArray();

    public static (string Params, string EncSecKey) Encrypt(string plainJson)
    {
        var secretKey = RandomKey(16);
        var first = AesEncrypt(plainJson, PresetKey);
        var second = AesEncrypt(first, Encoding.UTF8.GetBytes(secretKey));
        var encSec = RsaEncrypt(secretKey);
        return (second, encSec);
    }

    private static string RandomKey(int size)
    {
        Span<char> buf = stackalloc char[size];
        for (int i = 0; i < size; i++)
        {
            buf[i] = RandomChars[RandomNumberGenerator.GetInt32(RandomChars.Length)];
        }
        return new string(buf);
    }

    private static string AesEncrypt(string text, byte[] key)
    {
        using var aes = Aes.Create();
        aes.Mode = CipherMode.CBC;
        aes.Padding = PaddingMode.PKCS7;
        aes.KeySize = 128;
        aes.Key = key;
        aes.IV = IV;
        using var encryptor = aes.CreateEncryptor();
        var bytes = Encoding.UTF8.GetBytes(text);
        var encrypted = encryptor.TransformFinalBlock(bytes, 0, bytes.Length);
        return Convert.ToBase64String(encrypted);
    }

    private static string RsaEncrypt(string secretKey)
    {
        // 反转字符串，按 UTF-8 hex 解析为 BigInt（与 JS 端 BigInt('0x' + hex(reversed)) 等价）
        var reversed = new string(secretKey.Reverse().ToArray());
        var bytes = Encoding.UTF8.GetBytes(reversed);
        var hex = Convert.ToHexString(bytes);
        var baseValue = ParsePositiveHex(hex);
        var encrypted = BigInteger.ModPow(baseValue, Exponent, Modulus);
        var hexResult = encrypted.ToString("x", CultureInfo.InvariantCulture);
        return hexResult.PadLeft(256, '0');
    }

    /// <summary>
    /// .NET BigInteger 用 HexNumber 解析时，高位为 8-f 会被当成负数；
    /// 前缀加一个 "0" 强制正数。
    /// </summary>
    private static BigInteger ParsePositiveHex(string hex)
    {
        return BigInteger.Parse("0" + hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
    }
}
