# Anvil 测试报告解读（Q&A）

本文是对 `docs/anvil-exact-in-test-report.md` 与 `docs/anvil-exact-out-test-report.md` 两份测试报告中常见疑问的集中解释，内容整理自针对以下问题的问答：

1. "断言"是什么意思？断言 = assert 表示失败吗？
2. hook 本来就没有余额，为什么报告说"hook 四种代币余额归零"？
3. 给 fb 池加流动性为什么会涉及 wrap？
4. 测试涉及的两个 poolId 是多少？

---

## 1. "断言"不是失败，恰恰是"验证通过"

断言（assert）是测试里的**检查点**：测试代码写下一个预期条件，运行时核对实际情况：

- 条件成立 → 断言**通过**，测试 PASS
- 条件不成立 → 断言**失败**，测试 FAIL（并指出是哪一条）

本次 anvil 套件 3 个用例全部 PASS，即所有断言都成立。报告中"每个用例均断言 X"的意思是"每个用例都**验证了** X 且验证通过"。`test/anvil/RingFallbackHookAnvilTest.sol` 中的典型断言例如：

```solidity
assertEq(userDelta.amount0(), -50, "user delta amount0");  // 用户确实只付了 50
assertEq(r.amountOut, 48, "...");                           // fb 输出确实是 48
assertEq(curPrice, SQRT_PRICE_1_1, "cur price unchanged");  // cur 池确实没动
```

## 2. hook "本来就没有余额"与"余额归零"的关系

正因如此才要断言。hook 在整个 swap 过程中是**中转方**，链路为：

```
_executeFbSwap: poolManager.take(fewToken) → wrap 成 origin 代币交给用户
               poolManager.take(用户付出的 origin 代币) → unwrap 成 fewToken 还给 PoolManager
```

take/unwrap 会让代币**瞬时经过 hook 的账户**。如果在 swap 结束后 hook 仍持有任何一种代币（token0 / token1 / few0 / few1 任意一个余额 > 0），就说明 wrap/unwrap 不是严格 1:1、或结算有遗漏、或资金被卡在 hook 里。因此断言"四种代币余额 == 0"验证的是不变式：**swap 前是 0，swap 后仍是 0，中途的过账资金全部结清**。

## 3. 给 fb 池加流动性为什么涉及 wrap

测试里存在两个池子、两种代币形态：

```
cur 池（挂 hook）：token0 / token1          ← 直接交易 origin 代币
fb 池（无 hook）： few1 / few0              ← 只交易 wrap 后的 FewToken
```

给 fb 池加流动性时，LP（测试合约）手里只有 origin 代币，必须先 `token0 --wrap--> few0`、`token1 --wrap--> few1`，再把 few0 + few1 存入 fb 池：

```solidity
IFewWrappedToken(few0).wrap(MINT * 2);   // origin → fewToken
IFewWrappedToken(few1).wrap(MINT * 2);
liquidityRouter.modifyLiquidity(fbKey, ...liquidityDelta: 100000...);
```

报告提到的"差 1 wei 下溢"发生在这一步：cur 池加流动性会从 LP 扣 1 wei 取整灰尘（深度只有 100，量太小），与 wrap 共用同一个 LP 余额，导致 `wrap(全额)` 时差 1 wei。这不是合约缺陷，是测试搭建时的余量问题（LP 初始资金放大 10 倍后解决）。

## 4. 测试涉及的两个 poolId

| 项目 | 值 |
| --- | --- |
| PoolManager（主网 fork 上复用） | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| token0（cur currency0，origin） | `0x1d1499e622D69689cdf9004d05Ec547d650Ff211` |
| token1（cur currency1，origin） | `0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9` |
| few0 = wrap(token0)（fb currency1） | `0x5Fa39CD9DD20a3A77BA0CaD164bD5CF0d7bb3303` |
| few1 = wrap(token1)（fb currency0） | `0x4f81992FCe2E1846dD528eC0102e6eE1f61ed3e2` |
| RingFallbackHook | `0xc29a3eBdD7F47cab4Cc3718E5Fb94a37307f0088`（权限掩码 `0x88`） |

- **cur poolId**（挂 hook 的 origin 池，token0/token1，深度 100）：
  `0x75f960649ac6c60394751f41924367ae3abf4547ed5a6d34c6cfa576e80e5d12`
- **fb poolId**（无 hook 的 FewToken 池，few1/few0，深度 100000）：
  `0xf7fb78b6bec1c340f75930d96ae6e585230d942ab4d48853ab53e822bd9ed0e2`

注意：mock 代币与 hook 地址由测试在 fork 上部署，随 fork head 推进而变化；重新运行测试会得到新地址，但 poolId 逻辑与数值结论不变（地址顺序对调的设计不变）。

## 5. 两份报告关键数字速查

地址顺序对调（`token0 < token1` 但 `few0 > few1`，即 `orderAligned = false`），两个用例都路由到 fb 池，`fbLiquidity`（hook 源码中 `_beforeSwap` 的 `poolManager.getLiquidity(fbPoolId)` 读数）均为 **100000**：

| 用例 | inputDelta | outputDelta | specifiedDelta | unspecifiedDelta | 用户 BalanceDelta |
| --- | --- | --- | --- | --- | --- |
| exact-in 50 | `-50`（delta.amount1） | `+48`（delta.amount0） | `+50` | `-48` | `(-50, +48)` |
| exact-out 100 | `-102`（delta.amount1） | `+100`（delta.amount0） | `-100` | `+102` | `(-102, +100)` |

数值解读：

- **inputDelta / outputDelta**：`_executeFbSwap` 里 fb 池 swap 返回的 `BalanceDelta`。因为 fb 池代币顺序与 cur 池对调（`fbZeroForOne = params.zeroForOne == orderAligned = false`），本例中输入是 fb 池的 currency1（few0）、输出是 currency0（few1），所以 inputDelta 取 `delta.amount1()`（负值），outputDelta 取 `delta.amount0()`（正值）。
- **specifiedDelta**：`-amountSpecified`，作用是让 PoolManager 在 cur 池的 `amountToSwap` 归零（跳过 cur 池实际换币）；exact-in 时为正（+50 / +100 对应返回值符号约定），exact-out 时为负。
- **unspecifiedDelta**：exact-in 时为 `-amountOut`（-48），exact-out 时为 `+amountIn`（+102），由 afterSwap 换算成 hookDelta 从调用者的 swapDelta 中扣除，完成结算。
- **费用口径**：exact-in 50 @ L=100000、fee 0.05%：费用向上取整 1 wei，实换 49，输出向下取整 → 48。exact-out 100：100 输出 + 1 深度取整 + 1 费用 = 102 输入。均与链上实测一致。
